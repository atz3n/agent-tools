#!/usr/bin/env python3
"""Odoo proxy server that exposes task information from Odoo.

Manages an Odoo session internally and exposes REST endpoints:
  GET /task/data?id=<task_id>   — task fields via project.task.web_read
  GET /task/messages?id=<id>    — thread messages via mail.thread.messages

Credentials are read from environment variables.
"""

from __future__ import annotations

import http.server
import json
import signal
from urllib.parse import parse_qs, urlparse

from .config import PORT, load_config, logger
from .session import get_session
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
    """Handle requests to the Odoo proxy endpoints."""

    def _send_json(self, status: int, data: dict | list) -> None:
        """Send a JSON response."""
        body = json.dumps(data, indent=2, default=str).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _handle_task_data(self, params: dict) -> None:
        """Handle GET /task/data?id=<task_id>."""
        id_values = params.get("id", [])
        if not id_values or not id_values[0]:
            self._send_json(400, {"error": "missing required parameter: id"})
            return

        try:
            task_id = int(id_values[0])
        except ValueError:
            self._send_json(400, {"error": f"invalid id parameter: {id_values[0]!r}"})
            return

        session = get_session({
            "db": _session_config["db"],
            "url": _session_config["url"],
            "user": _session_config["user"],
            "password": _session_config["password"],
        })
        try:
            result = session.call_rpc(
                model="project.task",
                method="web_read",
                args=[[task_id]],
                kwargs={
                    "context": {
                        "lang": "en_GB",
                        "tz": "Europe/Berlin",
                        "uid": 0,
                        "bin_size": True,
                    },
                    "specification": {
                        "id": {},
                        "name": {},
                        "display_name": {},
                        "description": {},
                        "priority": {},
                        "state": {},
                        "stage_id": {"fields": {"display_name": {}}},
                        "project_id": {"fields": {"display_name": {}}},
                        "partner_id": {"fields": {"display_name": {}}},
                        "user_ids": {"fields": {"display_name": {}}},
                        "date_deadline": {},
                        "planned_date_begin": {},
                        "progress": {},
                        "remaining_hours": {},
                        "effective_hours": {},
                        "total_hours_spent": {},
                        "tag_ids": {"fields": {"display_name": {}, "color": {}}},
                        "company_id": {"fields": {"display_name": {}}},
                        "rating_count": {},
                        "rating_avg": {},
                        "subtask_count": {},
                        "dependent_tasks_count": {},
                    },
                },
            )
            self._send_json(200, {"task": result[0] if result else None})
        except RuntimeError as exc:
            _log("GET", self.path, 502, self.client_address[0])
            self._send_json(502, {"error": str(exc)})

    def _handle_task_messages(self, params: dict) -> None:
        """Handle GET /task/messages?id=<thread_id>."""
        id_values = params.get("id", [])
        if not id_values or not id_values[0]:
            self._send_json(400, {"error": "missing required parameter: id"})
            return

        try:
            thread_id = int(id_values[0])
        except ValueError:
            self._send_json(400, {"error": f"invalid id parameter: {id_values[0]!r}"})
            return

        session = get_session({
            "db": _session_config["db"],
            "url": _session_config["url"],
            "user": _session_config["user"],
            "password": _session_config["password"],
        })
        try:
            result = session.get_messages(thread_id=thread_id)
            messages = result.get("messages", [])
            self._send_json(200, {"messages": messages})
        except RuntimeError as exc:
            _log("GET", self.path, 502, self.client_address[0])
            self._send_json(502, {"error": str(exc)})

    def _handle_task_message_post(self, params: dict) -> None:
        """Handle POST /task/message?id=<thread_id>."""
        id_values = params.get("id", [])
        if not id_values or not id_values[0]:
            self._send_json(400, {"error": "missing required parameter: id"})
            return

        try:
            thread_id = int(id_values[0])
        except ValueError:
            self._send_json(400, {"error": f"invalid id parameter: {id_values[0]!r}"})
            return

        content_length = int(self.headers.get("Content-Length", 0))
        raw_body = self.rfile.read(content_length) if content_length > 0 else b"{}"
        try:
            body_data = json.loads(raw_body)
        except json.JSONDecodeError:
            self._send_json(400, {"error": "invalid JSON body"})
            return

        body = body_data.get("body", "")
        if not body:
            self._send_json(400, {"error": "missing required field: body"})
            return

        message_type = body_data.get("message_type", "comment")
        subtype_xmlid = body_data.get("subtype_xmlid", "mail.mt_note")

        proxy_session = get_session({
            "db": _session_config["db"],
            "url": _session_config["url"],
            "user": _session_config["user"],
            "password": _session_config["password"],
        })
        try:
            result = proxy_session.post_message(
                thread_id=thread_id,
                body=body,
                message_type=message_type,
                subtype_xmlid=subtype_xmlid,
            )
            self._send_json(200, {"message": result})
        except RuntimeError as exc:
            _log("POST", self.path, 502, self.client_address[0])
            self._send_json(502, {"error": str(exc)})

    def _proxy(self, method: str) -> None:
        raw_path = self.path
        path = raw_path.split("?")[0]

        if not is_allowed_endpoint(path):
            _log(method, raw_path, 404, self.client_address[0])
            self._send_json(404, {"error": "endpoint not found"})
            return

        params = parse_qs(urlparse(raw_path).query)

        match method:
            case "GET":
                match path:
                    case "/task/data":
                        _log("GET", raw_path, 200, self.client_address[0])
                        self._handle_task_data(params)
                    case "/task/messages":
                        _log("GET", raw_path, 200, self.client_address[0])
                        self._handle_task_messages(params)
                    case _:
                        self._send_json(404, {"error": "not found"})
            case "POST":
                match path:
                    case "/task/message":
                        _log("POST", raw_path, 200, self.client_address[0])
                        self._handle_task_message_post(params)
                    case _:
                        self._send_json(404, {"error": "not found"})
            case _:
                _log(method, raw_path, 405, self.client_address[0])
                self._send_json(405, {"error": "method not allowed"})

    def do_GET(self) -> None:
        self._proxy("GET")

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
# Global config (set by main before starting the server)
# ---------------------------------------------------------------------------

_session_config: dict = {}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    _session_config = load_config()

    server = http.server.HTTPServer(("0.0.0.0", PORT), ProxyHandler)
    logger.info("Odoo proxy listening on 127.0.0.1:%d — waiting for requests", PORT)
    logger.info("  GET /task/data?id=<task_id>    — task fields")
    logger.info("  GET /task/messages?id=<id>     — thread messages")
    logger.info("  POST /task/message?id=<id>     — post note to thread")

    signal.signal(signal.SIGTERM, lambda s, f: _shutdown(server, s, f))
    signal.signal(signal.SIGINT, lambda s, f: _shutdown(server, s, f))

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    server.server_close()
