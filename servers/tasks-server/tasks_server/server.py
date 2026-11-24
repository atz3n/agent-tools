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
import os
import re
import signal
import threading
from datetime import datetime
from urllib.parse import parse_qs, urlparse

from .config import BIND_HOST, PORT, init_tasks_dir, logger
from .storage import (
    VALID_PRIORITIES,
    VALID_STATUSES,
    create_project,
    create_task,
    delete_task,
    get_task,
    list_projects,
    list_tasks,
    update_task,
    valid_project_name,
)
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
    """Gracefully shut down the HTTP server on SIGTERM/SIGINT.

    ``server.shutdown()`` waits for the ``serve_forever()`` loop to exit, so
    it must not run on the signal handler's own (main) thread — that
    deadlocks. Hand it to a short-lived thread instead.
    """
    threading.Thread(target=server.shutdown, daemon=True).start()


# ---------------------------------------------------------------------------
# Request handler
# ---------------------------------------------------------------------------


# Belt-and-braces against the UI's attribute/JS interpolation of task data:
# due dates are dates, not free-form strings.
_DUE_DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}\Z")


def _field_type_error(body: dict) -> str | None:
    """Error message when a request-body field has a type storage can't use.

    Storage would otherwise crash mid-write (e.g. ``title.lower()`` on an
    int), dropping the connection without a response or a log line.
    """
    if "title" in body and (not isinstance(body["title"], str) or not body["title"].strip()):
        return "title must be a non-empty string"
    if "description" in body and not isinstance(body["description"], str):
        return "description must be a string"
    if "due_date" in body and body["due_date"] is not None:
        if not isinstance(body["due_date"], str):
            return "due_date must be a string or null"
        if not _DUE_DATE_RE.match(body["due_date"]):
            return "due_date must be a YYYY-MM-DD string or null"
        try:
            datetime.strptime(body["due_date"], "%Y-%m-%d")
        except ValueError:
            # The regex only proves the shape — 2030-02-30/2030-13-01 would
            # otherwise be stored and render as "Invalid Date" (or silently
            # roll) in the UI.
            return "due_date must be a YYYY-MM-DD string or null"
    if "tags" in body and (
        not isinstance(body["tags"], list) or not all(isinstance(t, str) for t in body["tags"])
    ):
        return "tags must be a list of strings"
    return None


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

    def _read_body(self) -> tuple[dict | None, str]:
        """Read and parse a JSON object request body.

        Returns ``(body, error)``. A malformed ``Content-Length``, invalid
        JSON, or a JSON value that is not an object yields ``(None, reason)``
        so every caller answers 400 instead of crashing on ``.get()``.
        """
        try:
            content_length = int(self.headers.get("Content-Length", 0))
        except ValueError:
            return None, "invalid Content-Length header"
        if content_length < 0:
            # A negative length would make rfile.read() read until EOF.
            return None, "invalid Content-Length header"
        raw_body = self.rfile.read(content_length) if content_length > 0 else b"{}"
        try:
            payload = json.loads(raw_body)
        except json.JSONDecodeError:
            return None, "invalid JSON body"
        if not isinstance(payload, dict):
            return None, "body must be a JSON object"
        return payload, ""

    def _handle_tasks_list(self, params: dict) -> None:
        """Handle GET /tasks."""
        project = params.get("project", [None])[0]
        status = params.get("status", [None])[0]
        if project is not None and not valid_project_name(project):
            # A malformed filter must not scan outside TASKS_DIR.
            _log("GET", self.path, 400, self.client_address[0])
            self._send_json(400, {"error": "invalid project filter"})
            return
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
        body, body_error = self._read_body()
        if body is None:
            _log("POST", self.path, 400, self.client_address[0])
            self._send_json(400, {"error": body_error})
            return

        title = body.get("title")
        if not title:
            _log("POST", self.path, 400, self.client_address[0])
            self._send_json(400, {"error": "missing required field: title"})
            return

        status = body.get("status", "open")
        if not isinstance(status, str) or status not in VALID_STATUSES:
            _log("POST", self.path, 400, self.client_address[0])
            expected = ", ".join(sorted(VALID_STATUSES))
            self._send_json(400, {"error": f"invalid status: {status!r} (expected one of: {expected})"})
            return

        priority = body.get("priority", "medium")
        if not isinstance(priority, str) or priority not in VALID_PRIORITIES:
            _log("POST", self.path, 400, self.client_address[0])
            expected = ", ".join(sorted(VALID_PRIORITIES))
            self._send_json(400, {"error": f"invalid priority: {priority!r} (expected one of: {expected})"})
            return

        project = body.get("project", "default")
        if not valid_project_name(project):
            _log("POST", self.path, 400, self.client_address[0])
            self._send_json(400, {"error": f"invalid project name: {project!r}"})
            return

        type_error = _field_type_error(body)
        if type_error:
            _log("POST", self.path, 400, self.client_address[0])
            self._send_json(400, {"error": type_error})
            return

        try:
            task = create_task(
                title=title,
                project=project,
                status=status,
                priority=priority,
                due_date=body.get("due_date"),
                tags=body.get("tags"),
                description=body.get("description", ""),
            )
        except ValueError as exc:
            # A project name that the volume occupies with a non-directory
            # (raised by _ensure_project_dir) — same 400 shape as the
            # invalid-name checks above.
            _log("POST", self.path, 400, self.client_address[0])
            self._send_json(400, {"error": str(exc)})
            return
        _log("POST", self.path, 201, self.client_address[0])
        self._send_json(201, {"task": task})

    def _handle_task_update(self, task_id: int) -> None:
        """Handle PATCH /tasks/{id}."""
        body, body_error = self._read_body()
        if body is None:
            _log("PATCH", self.path, 400, self.client_address[0])
            self._send_json(400, {"error": body_error})
            return

        if "status" in body and (not isinstance(body["status"], str) or body["status"] not in VALID_STATUSES):
            _log("PATCH", self.path, 400, self.client_address[0])
            expected = ", ".join(sorted(VALID_STATUSES))
            self._send_json(400, {"error": f"invalid status: {body['status']!r} (expected one of: {expected})"})
            return

        if "priority" in body and (not isinstance(body["priority"], str) or body["priority"] not in VALID_PRIORITIES):
            _log("PATCH", self.path, 400, self.client_address[0])
            expected = ", ".join(sorted(VALID_PRIORITIES))
            self._send_json(400, {"error": f"invalid priority: {body['priority']!r} (expected one of: {expected})"})
            return

        type_error = _field_type_error(body)
        if type_error:
            _log("PATCH", self.path, 400, self.client_address[0])
            self._send_json(400, {"error": type_error})
            return

        # Reject project values that could escape TASKS_DIR; empty/non-string
        # values keep the documented partial-update ignore semantics.
        new_project = body.get("project")
        if new_project is not None and (not isinstance(new_project, str) or new_project.strip()):
            if not valid_project_name(new_project):
                _log("PATCH", self.path, 400, self.client_address[0])
                self._send_json(400, {"error": f"invalid project name: {new_project!r}"})
                return

        try:
            task = update_task(task_id, body)
        except ValueError as exc:
            # Move target occupied by a non-directory on the volume.
            _log("PATCH", self.path, 400, self.client_address[0])
            self._send_json(400, {"error": str(exc)})
            return
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
        body, body_error = self._read_body()
        if body is None:
            _log("POST", self.path, 400, self.client_address[0])
            self._send_json(400, {"error": body_error})
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

        if not valid_project_name(name):
            _log("POST", self.path, 400, self.client_address[0])
            self._send_json(400, {"error": f"invalid project name: {name!r} "
                                           "(single path segment: alnum, then alnum, spaces, '-', '_', '.')"})
            return

        try:
            create_project(name)
        except ValueError as exc:
            _log("POST", self.path, 400, self.client_address[0])
            self._send_json(400, {"error": str(exc)})
            return
        _log("POST", self.path, 201, self.client_address[0])
        self._send_json(201, {"project": name})

    def _serve_static(self, path: str, content_type: str) -> None:
        """Serve a static file from the ui/ directory.

        The resolved target must stay inside ui/ — path-traversal attempts
        (``..`` segments smuggled through the /css/ and /js/ prefixes) are
        refused with 404, same as a missing file.
        """
        ui_root = os.path.realpath(os.path.join(os.path.dirname(os.path.dirname(__file__)), "ui"))
        ui_path = os.path.realpath(os.path.join(ui_root, path))
        if not ui_path.startswith(ui_root + os.sep):
            _log("GET", self.path, 404, self.client_address[0])
            self._send_json(404, {"error": "file not found"})
            return
        try:
            with open(ui_path, "rb") as f:
                content = f.read()
        except OSError:
            # Missing file, a directory (e.g. "/css/"), or unreadable entry —
            # all answered like a missing file, never as a crashed connection.
            _log("GET", self.path, 404, self.client_address[0])
            self._send_json(404, {"error": "file not found"})
            return
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)
        _log("GET", self.path, 200, self.client_address[0])

    def _handle_ui(self) -> None:
        """Handle GET /ui — serve the HTML UI."""
        self._serve_static("index.html", "text/html; charset=utf-8")

    def _handle_static(self) -> None:
        """Handle GET /css/* and /js/* — serve static assets.

        The query string is stripped first (cache-busting ``?v=…``), so GET
        opens the same file ``_handle_head``/``_static_status`` stats.
        """
        path = self.path.split("?")[0]
        if path.startswith("/css/"):
            self._serve_static(path.lstrip("/"), "text/css; charset=utf-8")
        else:
            self._serve_static(path.lstrip("/"), "application/javascript")

    def _handle_head(self, path: str) -> None:
        """Handle HEAD — mirror the status GET would return, without a body."""
        if path == "/tasks":
            # Mirror GET's 400 for an unsafe project filter, not just 200.
            project = parse_qs(urlparse(self.path).query).get("project", [None])[0]
            bad_filter = project is not None and not valid_project_name(project)
            status, ct = (400 if bad_filter else 200), "application/json"
        elif path == "/projects":
            status, ct = 200, "application/json"
        elif path == "/ui":
            status, ct = self._static_status("index.html"), "text/html; charset=utf-8"
        elif path.startswith("/css/"):
            status, ct = self._static_status(path.lstrip("/")), "text/css; charset=utf-8"
        elif path.startswith("/js/"):
            status, ct = self._static_status(path.lstrip("/")), "application/javascript"
        elif _TASK_ID_RE.match(path):
            m = _TASK_ID_RE.match(path)
            found = get_task(int(m.group(1))) is not None  # type: ignore[union-attr]
            status, ct = (200 if found else 404), "application/json"
        else:
            status, ct = 404, ""
        _log("HEAD", self.path, status, self.client_address[0])
        self.send_response(status)
        if ct:
            self.send_header("Content-Type", ct)
        self.end_headers()

    def _static_status(self, rel: str) -> int:
        """200 when the ui/ asset exists as a readable file, else 404."""
        ui_root = os.path.realpath(os.path.join(os.path.dirname(os.path.dirname(__file__)), "ui"))
        ui_path = os.path.realpath(os.path.join(ui_root, rel))
        if not ui_path.startswith(ui_root + os.sep) or not os.path.isfile(ui_path):
            return 404
        return 200

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
                self._handle_head(path)
            case "GET":
                # Handlers log the real status once the response is known.
                match path:
                    case "/tasks":
                        self._handle_tasks_list(params)
                    case "/projects":
                        self._handle_projects_list()
                    case "/ui":
                        self._handle_ui()
                    case _ if path.startswith(("/css/", "/js/")):
                        self._handle_static()
                    case _:
                        # Could be /tasks/{id}
                        m = _TASK_ID_RE.match(path)
                        if m:
                            self._handle_task_get(int(m.group(1)))
                        else:
                            _log("GET", raw_path, 404, self.client_address[0])
                            self._send_json(404, {"error": "not found"})
            case "POST":
                match path:
                    case "/tasks":
                        self._handle_task_create()
                    case "/projects":
                        self._handle_projects_create()
                    case _:
                        _log("POST", raw_path, 404, self.client_address[0])
                        self._send_json(404, {"error": "not found"})
            case "PATCH":
                m = _TASK_ID_RE.match(path)
                if m:
                    self._handle_task_update(int(m.group(1)))
                else:
                    _log("PATCH", raw_path, 404, self.client_address[0])
                    self._send_json(404, {"error": "not found"})
            case "DELETE":
                m = _TASK_ID_RE.match(path)
                if m:
                    self._handle_task_delete(int(m.group(1)))
                else:
                    _log("DELETE", raw_path, 404, self.client_address[0])
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

if __name__ == "__main__":  # pragma: no cover
    init_tasks_dir()

    server = http.server.ThreadingHTTPServer((BIND_HOST, PORT), ProxyHandler)
    server.daemon_threads = True  # in-flight requests must not block shutdown
    logger.info("Tasks server listening on %s:%d", BIND_HOST, PORT)
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
