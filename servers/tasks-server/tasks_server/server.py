#!/usr/bin/env python3
"""Tasks server that CRUDs tasks stored as markdown files with YAML frontmatter.

REST endpoints:
  GET    /tasks              — list tasks (optional ?project=, ?status= filters)
  GET    /tasks/{id}         — get a single task by ID
  POST   /tasks              — create a new task
  PATCH  /tasks/{id}         — update a task (partial update)
  DELETE /tasks/{id}         — delete a task
  GET    /projects           — list all projects
  POST   /projects           — create a new project
"""

from __future__ import annotations

import http.server
import json
import re
import signal
from urllib.parse import parse_qs, urlparse

from .config import PORT, init_tasks_dir, logger
from .storage import create_project, create_task, delete_task, get_task, list_projects, list_tasks, update_task
from .whitelist import is_allowed_endpoint

# ---------------------------------------------------------------------------
# Logging helper
# ---------------------------------------------------------------------------


def _log(method: str, path: str, status: int, client_ip: str = "") -> None:
    """Log an endpoint call."""
    msg = f"{method} {path} {status}"
    if client_ip:
        msg = f"{msg} from {client_ip}"
    logger.info(msg)


def _shutdown(server: http.server.HTTPServer, signum: int, frame: object) -> None:
    """Gracefully shut down the HTTP server on SIGTERM/SIGINT."""
    server.shutdown()


# ---------------------------------------------------------------------------
# Request handler
# ---------------------------------------------------------------------------


class ProxyHandler(http.server.BaseHTTPRequestHandler):
    """Handle requests to the tasks server endpoints."""

    def _send_json(self, status: int, data: dict | list) -> None:
        """Send a JSON response."""
        body = json.dumps(data, indent=2, default=str).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self) -> dict:
        """Read and parse a JSON request body."""
        content_length = int(self.headers.get("Content-Length", 0))
        raw_body = self.rfile.read(content_length) if content_length > 0 else b"{}"
        try:
            return json.loads(raw_body)
        except json.JSONDecodeError:
            return None  # type: ignore[return-value]

    def _handle_tasks_list(self, params: dict) -> None:
        """Handle GET /tasks."""
        project = params.get("project", [None])[0]
        status = params.get("status", [None])[0]
        tasks = list_tasks(project=project, status=status)
        _log("GET", self.path, 200, self.client_address[0])
        self._send_json(200, {"tasks": tasks, "count": len(tasks)})

    def _handle_task_get(self, task_id: int) -> None:
        """Handle GET /tasks/{id}."""
        task = get_task(task_id)
        if task is None:
            _log("GET", self.path, 404, self.client_address[0])
            self._send_json(404, {"error": f"task {task_id} not found"})
            return
        _log("GET", self.path, 200, self.client_address[0])
        self._send_json(200, {"task": task})

    def _handle_task_create(self) -> None:
        """Handle POST /tasks."""
        body = self._read_body()
        if body is None:
            _log("POST", self.path, 400, self.client_address[0])
            self._send_json(400, {"error": "invalid JSON body"})
            return

        title = body.get("title")
        if not title:
            _log("POST", self.path, 400, self.client_address[0])
            self._send_json(400, {"error": "missing required field: title"})
            return

        task = create_task(
            title=title,
            project=body.get("project", "default"),
            status=body.get("status", "open"),
            priority=body.get("priority", "medium"),
            due_date=body.get("due_date"),
            tags=body.get("tags"),
            description=body.get("description", ""),
        )
        _log("POST", self.path, 201, self.client_address[0])
        self._send_json(201, {"task": task})

    def _handle_task_update(self, task_id: int) -> None:
        """Handle PATCH /tasks/{id}."""
        body = self._read_body()
        if body is None:
            _log("PATCH", self.path, 400, self.client_address[0])
            self._send_json(400, {"error": "invalid JSON body"})
            return

        task = update_task(task_id, body)
        if task is None:
            _log("PATCH", self.path, 404, self.client_address[0])
            self._send_json(404, {"error": f"task {task_id} not found"})
            return
        _log("PATCH", self.path, 200, self.client_address[0])
        self._send_json(200, {"task": task})

    def _handle_task_delete(self, task_id: int) -> None:
        """Handle DELETE /tasks/{id}."""
        if not delete_task(task_id):
            _log("DELETE", self.path, 404, self.client_address[0])
            self._send_json(404, {"error": f"task {task_id} not found"})
            return
        _log("DELETE", self.path, 200, self.client_address[0])
        self._send_json(200, {"deleted": True, "id": task_id})

    def _handle_projects_list(self) -> None:
        """Handle GET /projects."""
        projects = list_projects()
        _log("GET", self.path, 200, self.client_address[0])
        self._send_json(200, {"projects": projects, "count": len(projects)})

    def _handle_projects_create(self) -> None:
        """Handle POST /projects."""
        body = self._read_body()
        if body is None:
            _log("POST", self.path, 400, self.client_address[0])
            self._send_json(400, {"error": "invalid JSON body"})
            return

        name = body.get("name")
        if not name or not isinstance(name, str):
            _log("POST", self.path, 400, self.client_address[0])
            self._send_json(400, {"error": "missing required field: name"})
            return

        name = name.strip()
        if not name:
            _log("POST", self.path, 400, self.client_address[0])
            self._send_json(400, {"error": "project name cannot be empty"})
            return

        create_project(name)
        _log("POST", self.path, 201, self.client_address[0])
        self._send_json(201, {"project": name})

    def _serve_static(self, path: str, content_type: str) -> None:
        """Serve a static file from the ui/ directory."""
        import os

        ui_path = os.path.join(
            os.path.dirname(os.path.dirname(__file__)), "ui", path
        )
        try:
            with open(ui_path, "rb") as f:
                content = f.read()
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)
            _log("GET", self.path, 200, self.client_address[0])
        except FileNotFoundError:
            _log("GET", self.path, 404, self.client_address[0])
            self._send_json(404, {"error": "file not found"})

    def _handle_ui(self) -> None:
        """Handle GET /ui — serve the HTML UI."""
        self._serve_static("index.html", "text/html; charset=utf-8")

    def _handle_static(self) -> None:
        """Handle GET /css/* and /js/* — serve static assets."""
        if self.path.startswith("/css/"):
            self._serve_static(self.path.lstrip("/"), "text/css; charset=utf-8")
        else:
            self._serve_static(self.path.lstrip("/"), "application/javascript")

    def _proxy(self, method: str) -> None:
        raw_path = self.path
        path = raw_path.split("?")[0]

        if not is_allowed_endpoint(path):
            _log(method, raw_path, 404, self.client_address[0])
            self._send_json(404, {"error": "endpoint not found"})
            return

        params = parse_qs(urlparse(raw_path).query)

        match method:
            case "HEAD":
                is_static = path.startswith(("/css/", "/js/"))
                if path in ("/tasks", "/projects", "/ui") or _TASK_ID_RE.match(path) or is_static:
                    _log("HEAD", raw_path, 200, self.client_address[0])
                    if path == "/ui":
                        ct = "text/html; charset=utf-8"
                    elif path.startswith("/css/"):
                        ct = "text/css; charset=utf-8"
                    elif path.startswith("/js/"):
                        ct = "application/javascript"
                    else:
                        ct = "application/json"
                    self.send_response(200)
                    self.send_header("Content-Type", ct)
                    self.end_headers()
                else:
                    _log("HEAD", raw_path, 404, self.client_address[0])
                    self.send_response(404)
                    self.end_headers()
            case "GET":
                match path:
                    case "/tasks":
                        _log("GET", raw_path, 200, self.client_address[0])
                        self._handle_tasks_list(params)
                    case "/projects":
                        _log("GET", raw_path, 200, self.client_address[0])
                        self._handle_projects_list()
                    case "/ui":
                        _log("GET", raw_path, 200, self.client_address[0])
                        self._handle_ui()
                    case _ if path.startswith(("/css/", "/js/")):
                        _log("GET", raw_path, 200, self.client_address[0])
                        self._handle_static()
                    case _:
                        # Could be /tasks/{id}
                        m = _TASK_ID_RE.match(path)
                        if m:
                            task_id = int(m.group(1))
                            _log("GET", raw_path, 200, self.client_address[0])
                            self._handle_task_get(task_id)
                        else:
                            self._send_json(404, {"error": "not found"})
            case "POST":
                match path:
                    case "/tasks":
                        _log("POST", raw_path, 201, self.client_address[0])
                        self._handle_task_create()
                    case "/projects":
                        _log("POST", raw_path, 201, self.client_address[0])
                        self._handle_projects_create()
                    case _:
                        self._send_json(404, {"error": "not found"})
            case "PATCH":
                m = _TASK_ID_RE.match(path)
                if m:
                    task_id = int(m.group(1))
                    _log("PATCH", raw_path, 200, self.client_address[0])
                    self._handle_task_update(task_id)
                else:
                    self._send_json(404, {"error": "not found"})
            case "DELETE":
                m = _TASK_ID_RE.match(path)
                if m:
                    task_id = int(m.group(1))
                    _log("DELETE", raw_path, 200, self.client_address[0])
                    self._handle_task_delete(task_id)
                else:
                    self._send_json(404, {"error": "not found"})
            case _:
                _log(method, raw_path, 405, self.client_address[0])
                self._send_json(405, {"error": "method not allowed"})

    def do_GET(self) -> None:
        self._proxy("GET")

    def do_HEAD(self) -> None:
        self._proxy("HEAD")

    def do_POST(self) -> None:
        self._proxy("POST")

    def do_PATCH(self) -> None:
        self._proxy("PATCH")

    def do_PUT(self) -> None:
        self._proxy("PUT")

    def do_DELETE(self) -> None:
        self._proxy("DELETE")

    def log_message(self, format: str, *args: object) -> None:
        """Override to silence the default access log (we use _log instead)."""
        pass


# ---------------------------------------------------------------------------
# Compiled regex for /tasks/{id} matching
# ---------------------------------------------------------------------------

_TASK_ID_RE = re.compile(r"^/tasks/(\d+)$")

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    init_tasks_dir()

    server = http.server.HTTPServer(("0.0.0.0", PORT), ProxyHandler)
    logger.info("Tasks proxy listening on 127.0.0.1:%d — waiting for requests", PORT)
    logger.info("  GET    /tasks              — list tasks")
    logger.info("  GET    /tasks/{id}         — get a task")
    logger.info("  POST   /tasks              — create a task")
    logger.info("  PATCH  /tasks/{id}         — update a task")
    logger.info("  DELETE /tasks/{id}         — delete a task")
    logger.info("  GET    /projects           — list projects")

    signal.signal(signal.SIGTERM, lambda s, f: _shutdown(server, s, f))
    signal.signal(signal.SIGINT, lambda s, f: _shutdown(server, s, f))

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    server.server_close()
