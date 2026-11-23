#!/usr/bin/env python3
"""Tests for the tasks server."""

from __future__ import annotations

import http.client
import io
import json
import logging
import os
import sys
import tempfile
import time
import unittest
from typing import Any, cast
from unittest.mock import MagicMock, patch

# Ensure tasks_server is importable
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tasks_server import config, storage, whitelist  # noqa: E402
from tasks_server.server import ProxyHandler, _log, _shutdown  # noqa: E402


class _LogCapture(logging.Handler):
    """Captures log records for testing."""

    def __init__(self) -> None:
        super().__init__()
        self.records: list[logging.LogRecord] = []

    def emit(self, record: logging.LogRecord) -> None:
        self.records.append(record)


# ---------------------------------------------------------------------------
# Endpoint whitelist tests
# ---------------------------------------------------------------------------


class TestEndpointWhitelist(unittest.TestCase):
    """Test the endpoint whitelist."""

    def test_tasks_list_allowed(self) -> None:
        self.assertTrue(whitelist.is_allowed_endpoint('/tasks'))

    def test_tasks_list_with_query_allowed(self) -> None:
        self.assertTrue(whitelist.is_allowed_endpoint('/tasks?project=alpha'))

    def test_task_get_allowed(self) -> None:
        self.assertTrue(whitelist.is_allowed_endpoint('/tasks/1'))

    def test_task_get_large_id_allowed(self) -> None:
        self.assertTrue(whitelist.is_allowed_endpoint('/tasks/99999'))

    def test_projects_list_allowed(self) -> None:
        self.assertTrue(whitelist.is_allowed_endpoint('/projects'))

    def test_projects_with_query_allowed(self) -> None:
        self.assertTrue(whitelist.is_allowed_endpoint('/projects?foo=bar'))

    def test_css_static_allowed(self) -> None:
        self.assertTrue(whitelist.is_allowed_endpoint('/css/styles.css'))

    def test_js_static_allowed(self) -> None:
        self.assertTrue(whitelist.is_allowed_endpoint('/js/app.js'))


class TestBlockedEndpoints(unittest.TestCase):
    """Test that non-whitelisted endpoints are properly rejected."""

    def test_root_blocked(self) -> None:
        self.assertFalse(whitelist.is_allowed_endpoint('/'))

    def test_health_blocked(self) -> None:
        self.assertFalse(whitelist.is_allowed_endpoint('/health'))

    def test_api_prefix_blocked(self) -> None:
        self.assertFalse(whitelist.is_allowed_endpoint('/api'))

    def test_tasks_without_id_blocked(self) -> None:
        """GET /tasks/ should be rejected (needs numeric id)."""
        self.assertFalse(whitelist.is_allowed_endpoint('/tasks/'))

    def test_tasks_non_numeric_id_blocked(self) -> None:
        self.assertFalse(whitelist.is_allowed_endpoint('/tasks/abc'))

    def test_tasks_extra_segment_blocked(self) -> None:
        self.assertFalse(whitelist.is_allowed_endpoint('/tasks/1/comments'))

    def test_unknown_endpoint_blocked(self) -> None:
        self.assertFalse(whitelist.is_allowed_endpoint('/unknown'))

    def test_users_blocked(self) -> None:
        self.assertFalse(whitelist.is_allowed_endpoint('/users'))


# ---------------------------------------------------------------------------
# Configuration tests
# ---------------------------------------------------------------------------


class TestConfiguration(unittest.TestCase):
    """Test configuration loading."""

    def test_default_port(self) -> None:
        self.assertEqual(config.PORT, 8088)

    def test_default_tasks_dir(self) -> None:
        self.assertEqual(config.TASKS_DIR, "/data/tasks/")

    def test_custom_port_from_env(self) -> None:
        with patch.dict(os.environ, {'PROXY_PORT': '9999'}):
            import importlib
            importlib.reload(config)
            self.assertEqual(config.PORT, 9999)
            self.addCleanup(lambda: importlib.reload(config))


# ---------------------------------------------------------------------------
# Frontmatter parsing tests
# ---------------------------------------------------------------------------


class TestFrontmatterParsing(unittest.TestCase):
    """Test frontmatter parsing and formatting."""

    def test_parse_simple_frontmatter(self) -> None:
        text = '---\nid: 1\ntitle: "Test task"\nstatus: open\n---\n\nBody text\n'
        fm, body = storage.parse_frontmatter(text)
        self.assertEqual(fm['id'], 1)
        self.assertEqual(fm['title'], 'Test task')
        self.assertEqual(fm['status'], 'open')
        self.assertEqual(body.strip(), 'Body text')

    def test_parse_frontmatter_with_array(self) -> None:
        text = '---\nid: 1\ntags: ["bug", "auth"]\n---\n\nBody\n'
        fm, _ = storage.parse_frontmatter(text)
        self.assertEqual(fm['tags'], ['bug', 'auth'])

    def test_parse_frontmatter_with_null(self) -> None:
        text = '---\nid: 1\ndue_date:\n---\n\nBody\n'
        fm, _ = storage.parse_frontmatter(text)
        self.assertIsNone(fm['due_date'])

    def test_parse_frontmatter_with_priority(self) -> None:
        text = '---\nid: 1\npriority: high\n---\n\nBody\n'
        fm, _ = storage.parse_frontmatter(text)
        self.assertEqual(fm['priority'], 'high')

    def test_parse_no_frontmatter(self) -> None:
        text = 'Just plain markdown\n'
        fm, body = storage.parse_frontmatter(text)
        self.assertEqual(fm, {})
        self.assertEqual(body, 'Just plain markdown\n')

    def test_format_frontmatter(self) -> None:
        fm = {'id': 1, 'title': 'Test', 'status': 'open', 'tags': ['a', 'b']}
        output = storage.format_frontmatter(fm)
        self.assertIn('id: 1', output)
        self.assertIn('title: "Test"', output)
        self.assertIn('status: "open"', output)
        self.assertIn('tags: ["a", "b"]', output)

    def test_roundtrip(self) -> None:
        """Parse and format should roundtrip correctly."""
        original_fm = {
            'id': 42,
            'title': 'Roundtrip test',
            'status': 'closed',
            'priority': 'low',
            'due_date': None,
            'tags': ['test'],
            'created_at': '2026-07-27T10:00:00Z',
            'updated_at': '2026-07-27T11:00:00Z',
        }
        formatted = storage.format_frontmatter(original_fm)
        fm, _ = storage.parse_frontmatter(f'---\n{formatted}\n---\n\nBody\n')
        self.assertEqual(fm['id'], original_fm['id'])
        self.assertEqual(fm['title'], original_fm['title'])
        self.assertEqual(fm['status'], original_fm['status'])
        self.assertEqual(fm['priority'], original_fm['priority'])
        self.assertIsNone(fm['due_date'])
        self.assertEqual(fm['tags'], original_fm['tags'])

    def test_filename_from_title(self) -> None:
        """_filename_from_title should produce {id:03d}_{slug}.md."""
        self.assertEqual(storage._filename_from_title(1, "Fix login bug"), '001_fix-login-bug.md')
        self.assertEqual(storage._filename_from_title(42, "Add feature"), '042_add-feature.md')
        # Spaces and special chars are stripped
        self.assertEqual(storage._filename_from_title(3, "Hello, world!"), '003_hello-world.md')
        # Empty/whitespace title falls back to "untitled"
        self.assertEqual(storage._filename_from_title(5, ""), '005_untitled.md')


# ---------------------------------------------------------------------------
# Storage CRUD tests
# ---------------------------------------------------------------------------


class TestTaskCRUD(unittest.TestCase):
    """Test task CRUD operations."""

    def setUp(self) -> None:
        """Set up a temporary tasks directory."""
        self.tmpdir = tempfile.mkdtemp()
        self._orig_tasks_dir = config.TASKS_DIR
        config.TASKS_DIR = self.tmpdir
        # Initialize counter — pass dir explicitly since config.TASKS_DIR is
        # evaluated at import time and won't reflect the test override.
        config.init_tasks_dir(self.tmpdir)

    def tearDown(self) -> None:
        config.TASKS_DIR = self._orig_tasks_dir
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_create_task(self) -> None:
        task = storage.create_task(title="Test task", project="demo")
        self.assertEqual(task['title'], 'Test task')
        self.assertEqual(task['id'], 1)
        self.assertEqual(task['project'], 'demo')
        self.assertEqual(task['status'], 'open')
        self.assertEqual(task['priority'], 'medium')
        self.assertTrue(os.path.exists(os.path.join(self.tmpdir, 'demo', '001_test-task.md')))

    def test_update_task_moves_between_projects(self) -> None:
        """A project update must move the file into the new project folder."""
        storage.create_task(title="Move me", project="alpha")
        task = storage.update_task(1, {"project": "beta"})
        self.assertIsNotNone(task)
        assert task is not None
        self.assertEqual(task['project'], 'beta')
        self.assertEqual(task['filename'], '001_move-me.md')
        self.assertTrue(os.path.exists(os.path.join(self.tmpdir, 'beta', '001_move-me.md')))
        self.assertFalse(os.path.exists(os.path.join(self.tmpdir, 'alpha', '001_move-me.md')))
        # 6.8 — the source project directory is kept, even when now empty
        self.assertIn('alpha', storage.list_projects())

    def test_update_task_invalid_project_ignored(self) -> None:
        """Non-string / blank project values keep the task where it is."""
        storage.create_task(title="Stay", project="alpha")
        task = storage.update_task(1, {"project": "  "})
        assert task is not None
        self.assertEqual(task['project'], 'alpha')
        self.assertTrue(os.path.exists(os.path.join(self.tmpdir, 'alpha', '001_stay.md')))

    def test_create_task_with_all_fields(self) -> None:
        task = storage.create_task(
            title="Full task",
            project="proj",
            status="in_progress",
            priority="high",
            due_date="2026-12-31",
            tags=["urgent", "bug"],
            description="Important fix",
        )
        self.assertEqual(task['title'], 'Full task')
        self.assertEqual(task['status'], 'in_progress')
        self.assertEqual(task['priority'], 'high')
        self.assertEqual(task['due_date'], '2026-12-31')
        self.assertEqual(task['tags'], ['urgent', 'bug'])
        self.assertEqual(task['description'], 'Important fix')

    def test_filename_format(self) -> None:
        """File names should follow {id:03d}_{title}.md pattern."""
        task = storage.create_task(title="Fix login bug", project="proj")
        self.assertEqual(task['filename'], '001_fix-login-bug.md')
        self.assertTrue(os.path.exists(os.path.join(self.tmpdir, 'proj', '001_fix-login-bug.md')))

    def test_get_task(self) -> None:
        storage.create_task(title="Get me", project="p1")
        task = storage.get_task(1)
        assert task is not None
        self.assertEqual(task['title'], 'Get me')
        self.assertEqual(task['project'], 'p1')
        self.assertEqual(task['filename'], '001_get-me.md')

    def test_get_task_not_found(self) -> None:
        task = storage.get_task(999)
        self.assertIsNone(task)

    def test_update_task(self) -> None:
        storage.create_task(title="Old title", project="p1")
        updated = storage.update_task(1, {'title': 'New title', 'status': 'closed'})
        assert updated is not None
        self.assertEqual(updated['title'], 'New title')
        self.assertEqual(updated['status'], 'closed')
        # Filename should be renamed to match new title
        self.assertEqual(updated['filename'], '001_new-title.md')
        self.assertTrue(os.path.exists(os.path.join(self.tmpdir, 'p1', '001_new-title.md')))
        self.assertFalse(os.path.exists(os.path.join(self.tmpdir, 'p1', '001_old-title.md')))

    def test_update_task_not_found(self) -> None:
        updated = storage.update_task(999, {'title': 'ghost'})
        self.assertIsNone(updated)

    def test_delete_task(self) -> None:
        storage.create_task(title="Delete me", project="p1")
        self.assertTrue(storage.delete_task(1))
        self.assertIsNone(storage.get_task(1))

    def test_delete_task_not_found(self) -> None:
        self.assertFalse(storage.delete_task(999))

    def test_auto_increment_ids(self) -> None:
        t1 = storage.create_task(title="First", project="p1")
        t2 = storage.create_task(title="Second", project="p1")
        t3 = storage.create_task(title="Third", project="p1")
        self.assertEqual(t1['id'], 1)
        self.assertEqual(t2['id'], 2)
        self.assertEqual(t3['id'], 3)

    def test_counter_persistence(self) -> None:
        """Counter should survive across get/create calls (simulating restart)."""
        storage.create_task(title="Task 1", project="p1")
        # Simulate restart by re-reading counter
        next_id = storage._read_counter()
        self.assertEqual(next_id, 2)

    def test_list_tasks(self) -> None:
        storage.create_task(title="A", project="alpha")
        storage.create_task(title="B", project="beta")
        tasks = storage.list_tasks()
        self.assertEqual(len(tasks), 2)
        # Each task should include its filename
        self.assertIn('filename', tasks[0])

    def test_list_tasks_filter_by_project(self) -> None:
        storage.create_task(title="A", project="alpha")
        storage.create_task(title="B", project="beta")
        tasks = storage.list_tasks(project='alpha')
        self.assertEqual(len(tasks), 1)
        self.assertEqual(tasks[0]['title'], 'A')

    def test_list_tasks_filter_by_status(self) -> None:
        storage.create_task(title="Open task", project="p1", status="open")
        storage.create_task(title="Closed task", project="p1", status="closed")
        tasks = storage.list_tasks(status='closed')
        self.assertEqual(len(tasks), 1)
        self.assertEqual(tasks[0]['status'], 'closed')

    def test_list_tasks_filter_by_done_status(self) -> None:
        storage.create_task(title="Open task", project="p1", status="open")
        storage.create_task(title="Done task", project="p1", status="done")
        storage.create_task(title="Closed task", project="p1", status="closed")
        tasks = storage.list_tasks(status='done')
        self.assertEqual(len(tasks), 1)
        self.assertEqual(tasks[0]['status'], 'done')

    def test_list_tasks_filter_by_in_progress_status(self) -> None:
        storage.create_task(title="Open task", project="p1", status="open")
        storage.create_task(title="In Progress task", project="p1", status="in_progress")
        storage.create_task(title="Closed task", project="p1", status="closed")
        tasks = storage.list_tasks(status='in_progress')
        self.assertEqual(len(tasks), 1)
        self.assertEqual(tasks[0]['status'], 'in_progress')

    def test_list_tasks_filter_by_project_and_status(self) -> None:
        storage.create_task(title="A", project="alpha", status="open")
        storage.create_task(title="B", project="alpha", status="closed")
        storage.create_task(title="C", project="beta", status="open")
        tasks = storage.list_tasks(project='alpha', status='open')
        self.assertEqual(len(tasks), 1)
        self.assertEqual(tasks[0]['title'], 'A')

    def test_list_projects(self) -> None:
        storage.create_task(title="A", project="alpha")
        storage.create_task(title="B", project="beta")
        projects = storage.list_projects()
        self.assertIn('alpha', projects)
        self.assertIn('beta', projects)
        self.assertNotIn('.counter.json', projects)

    def test_create_project(self) -> None:
        name = storage.create_project("newproj")
        self.assertEqual(name, "newproj")
        self.assertTrue(os.path.exists(os.path.join(self.tmpdir, 'newproj')))

    def test_create_project_already_exists(self) -> None:
        """Creating a project that already exists should not raise."""
        storage.create_project("existing")
        name = storage.create_project("existing")
        self.assertEqual(name, "existing")


# ---------------------------------------------------------------------------
# HTTP handler tests
# ---------------------------------------------------------------------------


class _FakeHandler:
    """Minimal fake handler for testing endpoint methods directly."""

    def __init__(self) -> None:
        self.wfile = MagicMock()
        self.response_status = None
        self.response_headers: dict[str, str] = {}
        self.response_body = b''
        self.path = ''
        self.client_address = ('192.168.1.1', 54321)

    def send_response(self, status: int) -> None:
        self.response_status = status

    def send_header(self, key: str, value: str) -> None:
        self.response_headers[key] = value

    def end_headers(self) -> None:
        pass

    def write(self, data: bytes) -> None:
        self.response_body += data
        # Also record on wfile MagicMock for compatibility
        self.wfile.write(data)


def _make_handler() -> ProxyHandler:
    """Create a ProxyHandler with mocked socket and wfile."""
    handler = object.__new__(ProxyHandler)
    handler.path = ''
    handler.requestline = 'GET / HTTP/1.1'
    handler.request_version = 'HTTP/1.1'
    handler.client_address = ('192.168.1.1', 54321)
    mock_headers: http.client.HTTPMessage = http.client.HTTPMessage()
    mock_headers['Content-Type'] = 'application/json'
    mock_headers['Content-Length'] = '0'
    handler.headers = mock_headers
    handler.rfile = io.BytesIO(b'{}')
    handler.wfile = MagicMock()
    return handler


class TestHandlerEndpoints(unittest.TestCase):
    """Test HTTP endpoint handling via direct method calls."""

    def setUp(self) -> None:
        """Set up a temporary tasks directory."""
        self.tmpdir = tempfile.mkdtemp()
        self._orig_tasks_dir = config.TASKS_DIR
        config.TASKS_DIR = self.tmpdir
        config.init_tasks_dir(self.tmpdir)

    def tearDown(self) -> None:
        config.TASKS_DIR = self._orig_tasks_dir
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_get_tasks_list_empty(self) -> None:
        handler = _make_handler()
        handler._handle_tasks_list({})
        data = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])
        self.assertEqual(data['tasks'], [])
        self.assertEqual(data['count'], 0)

    def test_get_tasks_list_with_filter(self) -> None:
        storage.create_task(title="A", project="demo", status="open")
        storage.create_task(title="B", project="demo", status="closed")
        handler = _make_handler()
        handler._handle_tasks_list({'project': ['demo'], 'status': ['open']})
        data = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])
        self.assertEqual(len(data['tasks']), 1)
        self.assertEqual(data['tasks'][0]['title'], 'A')

    def test_get_task_by_id(self) -> None:
        storage.create_task(title="Find me", project="p1")
        handler = _make_handler()
        handler._handle_task_get(1)
        data = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])
        self.assertEqual(data['task']['title'], 'Find me')

    def test_get_task_not_found(self) -> None:
        handler = _make_handler()
        handler._handle_task_get(999)
        data = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])
        self.assertEqual(data['error'], 'task 999 not found')

    def test_create_task(self) -> None:
        payload = json.dumps({"title": "New task", "project": "demo", "priority": "high"})
        handler = _make_handler()
        handler.rfile = io.BytesIO(payload.encode())
        handler.headers.replace_header('Content-Length', str(len(payload)))
        handler._handle_task_create()
        data = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])
        self.assertEqual(data['task']['title'], 'New task')
        self.assertEqual(data['task']['priority'], 'high')

    def test_create_task_missing_title(self) -> None:
        payload = json.dumps({"project": "demo"})
        handler = _make_handler()
        handler.rfile = io.BytesIO(payload.encode())
        handler.headers.replace_header('Content-Length', str(len(payload)))
        handler._handle_task_create()
        data = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])
        self.assertEqual(data['error'], 'missing required field: title')

    def test_create_task_invalid_json(self) -> None:
        handler = _make_handler()
        handler.rfile = io.BytesIO(b'not json')
        handler.headers.replace_header('Content-Length', '8')
        handler._handle_task_create()
        data = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])
        self.assertEqual(data['error'], 'invalid JSON body')

    def test_patch_task(self) -> None:
        storage.create_task(title="Old", project="p1")
        payload = json.dumps({"title": "Updated", "status": "closed"})
        handler = _make_handler()
        handler.rfile = io.BytesIO(payload.encode())
        handler.headers.replace_header('Content-Length', str(len(payload)))
        handler._handle_task_update(1)
        data = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])
        self.assertEqual(data['task']['title'], 'Updated')
        self.assertEqual(data['task']['status'], 'closed')

    def test_patch_task_not_found(self) -> None:
        handler = _make_handler()
        handler._handle_task_update(999)
        data = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])
        self.assertEqual(data['error'], 'task 999 not found')

    def _capture_send(self, handler: Any) -> None:
        """Replace _send_json to record the status alongside the body."""
        def _send(status: int, data: dict | list) -> None:
            handler.sent_status = status
            handler.wfile.write(json.dumps(data).encode())
        handler._send_json = _send

    def _patch_status(self, status: str) -> tuple[int, dict]:
        """PATCH a status value and return (status code, response body)."""
        storage.create_task(title="Status task")
        payload = json.dumps({"status": status})
        handler = _make_handler()
        handler.rfile = io.BytesIO(payload.encode())
        handler.headers.replace_header('Content-Length', str(len(payload)))
        self._capture_send(handler)
        handler._handle_task_update(1)
        body = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])
        return handler.sent_status, body  # type: ignore[attr-defined,no-any-return]

    def test_patch_invalid_status_rejected(self) -> None:
        status_code, body = self._patch_status('invented')
        self.assertEqual(status_code, 400)
        self.assertIn('invalid status', body['error'])

    def test_patch_on_hold_status_accepted(self) -> None:
        status_code, body = self._patch_status('on-hold')
        self.assertEqual(status_code, 200)
        self.assertEqual(body['task']['status'], 'on-hold')

    def test_post_invalid_status_rejected(self) -> None:
        payload = json.dumps({"title": "X", "status": "nope"})
        handler = _make_handler()
        handler.rfile = io.BytesIO(payload.encode())
        handler.headers.replace_header('Content-Length', str(len(payload)))
        self._capture_send(handler)
        handler._handle_task_create()
        self.assertEqual(handler.sent_status, 400)  # type: ignore[attr-defined]
        body = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])
        self.assertIn('invalid status', body['error'])

    def _post_body(self, payload_obj: object) -> tuple[int, dict]:
        """POST a JSON body to /tasks and return (status code, response body)."""
        payload = json.dumps(payload_obj)
        handler = _make_handler()
        handler.rfile = io.BytesIO(payload.encode())
        handler.headers.replace_header('Content-Length', str(len(payload)))
        self._capture_send(handler)
        handler._handle_task_create()
        body = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])
        return handler.sent_status, body  # type: ignore[attr-defined,no-any-return]

    def _patch_body(self, payload_obj: object) -> tuple[int, dict]:
        """PATCH a JSON body onto a fresh task and return (status, body)."""
        storage.create_task(title="Type task")
        payload = json.dumps(payload_obj)
        handler = _make_handler()
        handler.rfile = io.BytesIO(payload.encode())
        handler.headers.replace_header('Content-Length', str(len(payload)))
        self._capture_send(handler)
        handler._handle_task_update(1)
        body = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])
        return handler.sent_status, body  # type: ignore[attr-defined,no-any-return]

    def test_post_nonstring_title_rejected(self) -> None:
        status_code, body = self._post_body({"title": 123})
        self.assertEqual(status_code, 400)
        self.assertIn('title must be a non-empty string', body['error'])

    def test_post_object_title_rejected(self) -> None:
        status_code, body = self._post_body({"title": {"a": 1}})
        self.assertEqual(status_code, 400)
        self.assertIn('title must be a non-empty string', body['error'])

    def test_post_nonlist_tags_rejected(self) -> None:
        status_code, body = self._post_body({"title": "X", "tags": "not-a-list"})
        self.assertEqual(status_code, 400)
        self.assertIn('tags must be a list of strings', body['error'])

    def test_post_nonstring_description_rejected(self) -> None:
        status_code, body = self._post_body({"title": "X", "description": 5})
        self.assertEqual(status_code, 400)
        self.assertIn('description must be a string', body['error'])

    def test_patch_nonstring_title_rejected(self) -> None:
        status_code, body = self._patch_body({"title": 456})
        self.assertEqual(status_code, 400)
        self.assertIn('title must be a non-empty string', body['error'])

    def test_patch_numeric_due_date_rejected(self) -> None:
        status_code, body = self._patch_body({"due_date": 20260101})
        self.assertEqual(status_code, 400)
        self.assertIn('due_date must be a string or null', body['error'])

    def test_patch_nonstring_priority_rejected(self) -> None:
        status_code, body = self._patch_body({"priority": 3})
        self.assertEqual(status_code, 400)
        self.assertIn('invalid priority', body['error'])

    def test_post_invalid_priority_rejected(self) -> None:
        """7.1 — priority is enum-gated on write, like status."""
        status_code, body = self._post_body({"title": "X", "priority": "urgent"})
        self.assertEqual(status_code, 400)
        self.assertIn('invalid priority', body['error'])

    def test_post_xss_priority_rejected(self) -> None:
        """7.1 — the stored-XSS payload must never reach storage."""
        status_code, body = self._post_body(
            {"title": "pri", "priority": "<img src=x onerror=alert(1)>"}
        )
        self.assertEqual(status_code, 400)
        self.assertIn('invalid priority', body['error'])
        self.assertEqual(storage.list_tasks(), [])

    def test_post_patch_xss_priority_rejected(self) -> None:
        """7.1 — the PATCH twin of the XSS gate."""
        status_code, body = self._patch_body(
            {"priority": "<img src=x onerror=alert(1)>"}
        )
        self.assertEqual(status_code, 400)
        self.assertIn('invalid priority', body['error'])
        task = storage.get_task(1) or {}
        self.assertNotIn('onerror', str(task.get('priority')))

    def test_post_all_valid_priorities_accepted(self) -> None:
        for i, prio in enumerate(('low', 'medium', 'high'), start=1):
            status_code, body = self._post_body({"title": f"P {prio}", "priority": prio})
            self.assertEqual(status_code, 201, prio)
            self.assertEqual(body['task']['priority'], prio)
            self.assertEqual(i, body['task']['id'])

    def test_patch_all_valid_priorities_accepted(self) -> None:
        for prio in ('low', 'medium', 'high'):
            status_code, body = self._patch_body({"priority": prio})
            self.assertEqual(status_code, 200, prio)
            self.assertEqual(body['task']['priority'], prio)

    def test_patch_null_due_date_accepted(self) -> None:
        status_code, body = self._patch_body({"due_date": None})
        self.assertEqual(status_code, 200)
        self.assertIsNone(body['task']['due_date'])

    def test_delete_task(self) -> None:
        storage.create_task(title="Delete me", project="p1")
        handler = _make_handler()
        handler._handle_task_delete(1)
        data = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])
        self.assertTrue(data['deleted'])
        self.assertEqual(data['id'], 1)

    def test_delete_task_not_found(self) -> None:
        handler = _make_handler()
        handler._handle_task_delete(999)
        data = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])
        self.assertEqual(data['error'], 'task 999 not found')

    def test_get_projects(self) -> None:
        storage.create_task(title="A", project="alpha")
        storage.create_task(title="B", project="beta")
        handler = _make_handler()
        handler._handle_projects_list()
        data = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])
        self.assertIn('alpha', data['projects'])
        self.assertIn('beta', data['projects'])
        self.assertEqual(data['count'], 2)

    def test_create_project(self) -> None:
        payload = json.dumps({"name": "newproj"})
        handler = _make_handler()
        handler.rfile = io.BytesIO(payload.encode())
        handler.headers.replace_header('Content-Length', str(len(payload)))
        handler._handle_projects_create()
        data = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])
        self.assertEqual(data['project'], 'newproj')

    def test_create_project_missing_name(self) -> None:
        payload = json.dumps({})
        handler = _make_handler()
        handler.rfile = io.BytesIO(payload.encode())
        handler.headers.replace_header('Content-Length', str(len(payload)))
        handler._handle_projects_create()
        data = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])
        self.assertEqual(data['error'], 'missing required field: name')

    def test_create_project_empty_name(self) -> None:
        payload = json.dumps({"name": "   "})
        handler = _make_handler()
        handler.rfile = io.BytesIO(payload.encode())
        handler.headers.replace_header('Content-Length', str(len(payload)))
        handler._handle_projects_create()
        data = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])
        self.assertEqual(data['error'], 'project name cannot be empty')

    def test_create_project_invalid_json(self) -> None:
        handler = _make_handler()
        handler.rfile = io.BytesIO(b'not json')
        handler.headers.replace_header('Content-Length', '8')
        handler._handle_projects_create()
        data = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])
        self.assertEqual(data['error'], 'invalid JSON body')

    # --- project-name safety (storage traversal, review 2.1) -------------------------

    def _post_json(self, handler: Any, obj: dict) -> None:
        payload = json.dumps(obj).encode()
        handler.rfile = io.BytesIO(payload)
        handler.headers.replace_header('Content-Length', str(len(payload)))

    def _sent(self, handler: Any) -> tuple[int, dict]:
        body = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])
        return handler.sent_status, body  # type: ignore[attr-defined,no-any-return]

    def _capture_status(self, handler: Any) -> None:
        self._capture_send(handler)

    def test_create_task_traversal_project_rejected(self) -> None:
        handler = _make_handler()
        self._capture_status(handler)
        self._post_json(handler, {"title": "X", "project": "../../escape"})
        handler._handle_task_create()
        status, body = self._sent(handler)
        self.assertEqual(status, 400)
        self.assertIn('invalid project name', body['error'])

    def test_create_task_absolute_project_rejected(self) -> None:
        handler = _make_handler()
        self._capture_status(handler)
        self._post_json(handler, {"title": "X", "project": "/tmp/evil"})
        handler._handle_task_create()
        status, body = self._sent(handler)
        self.assertEqual(status, 400)

    def test_create_task_project_trailing_newline_rejected(self) -> None:
        """8.1 — a trailing newline must not be treated as a valid project name."""
        handler = _make_handler()
        self._capture_status(handler)
        self._post_json(handler, {"title": "X", "project": "rev-newline\n"})
        handler._handle_task_create()
        status, body = self._sent(handler)
        self.assertEqual(status, 400)
        self.assertIn('invalid project name', body['error'])
        self.assertFalse(os.path.exists(os.path.join(self.tmpdir, 'rev-newline\n')))

    def test_create_project_traversal_name_rejected(self) -> None:
        handler = _make_handler()
        self._capture_status(handler)
        self._post_json(handler, {"name": "../rev-pwned"})
        handler._handle_projects_create()
        status, body = self._sent(handler)
        self.assertEqual(status, 400)
        self.assertIn('invalid project name', body['error'])
        self.assertFalse(os.path.exists(os.path.join(self.tmpdir, '..', 'rev-pwned')))

    def test_patch_traversal_project_rejected(self) -> None:
        storage.create_task(title="Move me", project="default")
        handler = _make_handler()
        self._capture_status(handler)
        self._post_json(handler, {"project": "/tmp/rev-moved"})
        handler._handle_task_update(1)
        status, body = self._sent(handler)
        self.assertEqual(status, 400)
        self.assertFalse(os.path.isdir('/tmp/rev-moved'))

    def test_patch_blank_project_still_ignored(self) -> None:
        storage.create_task(title="Stay", project="default")
        handler = _make_handler()
        self._capture_status(handler)
        self._post_json(handler, {"project": "   "})
        handler._handle_task_update(1)
        status, _body = self._sent(handler)
        self.assertEqual(status, 200)

    def test_tasks_list_traversal_filter_rejected(self) -> None:
        handler = _make_handler()
        self._capture_status(handler)
        handler._handle_tasks_list({'project': ['../secret-dir'], 'status': [None]})
        status, body = self._sent(handler)
        self.assertEqual(status, 400)
        self.assertIn('invalid project filter', body['error'])

    def test_non_whitelisted_path_returns_404(self) -> None:
        handler = _make_handler()
        handler.path = '/unknown'
        handler._proxy('GET')
        data = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])
        self.assertEqual(data['error'], 'endpoint not found')

    def test_method_not_allowed(self) -> None:
        handler = _make_handler()
        handler.path = '/tasks'
        handler._proxy('PUT')
        data = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])
        self.assertEqual(data['error'], 'method not allowed')


# ---------------------------------------------------------------------------
# Static file serving tests
# ---------------------------------------------------------------------------


class TestStaticFileServing(unittest.TestCase):
    """Test static file serving for CSS and JS assets."""

    def test_css_served_correctly(self) -> None:
        """CSS file should be served with correct content-type and body."""
        handler = cast(Any, _make_handler())
        handler.response_status = None
        handler.response_headers = {}
        handler.response_body = b''
        orig_write = handler.wfile.write

        def track_write(data: bytes) -> None:
            handler.response_body += data
            orig_write(data)

        handler.send_response = lambda s: setattr(handler, 'response_status', s)
        handler.send_header = lambda k, v: setattr(handler, 'response_headers', {**handler.response_headers, k: v})
        handler.end_headers = lambda: None
        handler.wfile.write = track_write

        handler.path = '/css/styles.css'
        handler._handle_static()
        self.assertEqual(handler.response_status, 200)
        self.assertIn('text/css', handler.response_headers.get('Content-Type', ''))
        self.assertIn(b':root {', handler.response_body)

    def test_js_served_correctly(self) -> None:
        """JS file should be served with correct content-type and body."""
        handler = cast(Any, _make_handler())
        handler.response_status = None
        handler.response_headers = {}
        handler.response_body = b''
        orig_write = handler.wfile.write

        def track_write(data: bytes) -> None:
            handler.response_body += data
            orig_write(data)

        handler.send_response = lambda s: setattr(handler, 'response_status', s)
        handler.send_header = lambda k, v: setattr(handler, 'response_headers', {**handler.response_headers, k: v})
        handler.end_headers = lambda: None
        handler.wfile.write = track_write

        handler.path = '/js/app.js'
        handler._handle_static()
        self.assertEqual(handler.response_status, 200)
        self.assertIn('application/javascript', handler.response_headers.get('Content-Type', ''))
        self.assertIn(b'let allTasks', handler.response_body)

    def test_missing_css_returns_404(self) -> None:
        handler = _make_handler()
        handler.path = '/css/missing.css'
        handler._handle_static()
        data = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])
        self.assertEqual(data['error'], 'file not found')

    def test_missing_js_returns_404(self) -> None:
        handler = _make_handler()
        handler.path = '/js/missing.js'
        handler._handle_static()
        data = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])
        self.assertEqual(data['error'], 'file not found')

    def test_css_directory_returns_404_not_crash(self) -> None:
        """Review 2.3 — '/css/' is whitelisted and names a directory; it must
        404 cleanly instead of raising IsADirectoryError."""
        handler = _make_handler()
        handler.path = '/css/'
        handler._handle_static()  # must not raise
        data = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])
        self.assertEqual(data['error'], 'file not found')

    def test_js_directory_returns_404_not_crash(self) -> None:
        handler = _make_handler()
        handler.path = '/js/'
        handler._handle_static()
        data = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])
        self.assertEqual(data['error'], 'file not found')

    def test_path_traversal_blocked(self) -> None:
        """'..' segments smuggled through /css/ must not escape the ui/ dir."""
        handler = _make_handler()
        handler.path = '/css/../../../../etc/passwd'
        handler._handle_static()
        data = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])
        self.assertEqual(data['error'], 'file not found')
        for call in cast(MagicMock, handler.wfile).write.call_args_list:
            self.assertNotIn(b'root:', call[0][0])

    def test_path_traversal_via_js_blocked(self) -> None:
        handler = _make_handler()
        handler.path = '/js/../../../README.md'
        handler._handle_static()
        data = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])
        self.assertEqual(data['error'], 'file not found')

    def test_ui_html_served_correctly(self) -> None:
        """UI HTML should be served with correct content-type and body."""
        handler = cast(Any, _make_handler())
        handler.response_status = None
        handler.response_headers = {}
        handler.response_body = b''
        orig_write = handler.wfile.write

        def track_write(data: bytes) -> None:
            handler.response_body += data
            orig_write(data)

        handler.send_response = lambda s: setattr(handler, 'response_status', s)
        handler.send_header = lambda k, v: setattr(handler, 'response_headers', {**handler.response_headers, k: v})
        handler.end_headers = lambda: None
        handler.wfile.write = track_write

        handler.path = '/ui'
        handler._handle_ui()
        self.assertEqual(handler.response_status, 200)
        self.assertIn('text/html', handler.response_headers.get('Content-Type', ''))
        self.assertIn(b'<html', handler.response_body)


# ---------------------------------------------------------------------------
# Storage _parse_value tests
# ---------------------------------------------------------------------------


class TestParseValue(unittest.TestCase):
    """Test storage._parse_value edge cases."""

    def test_quoted_string_with_comma(self) -> None:
        """Quoted strings containing commas should not be split into arrays."""
        # This tests the fix: quote stripping must happen before comma check
        result = storage._parse_value('"hello, world"')
        self.assertEqual(result, 'hello, world')

    def test_single_quoted_string_with_comma(self) -> None:
        """Single-quoted strings containing commas should not be split."""
        result = storage._parse_value("'hello, world'")
        self.assertEqual(result, 'hello, world')

    def test_unquoted_string_with_comma(self) -> None:
        """Unquoted comma-separated values should still be split into arrays."""
        result = storage._parse_value('one, two, three')
        self.assertEqual(result, ['one', 'two', 'three'])

    def test_inline_array(self) -> None:
        """Inline arrays should still be parsed."""
        result = storage._parse_value('["tag1", "tag2"]')
        self.assertEqual(result, ['tag1', 'tag2'])


# ---------------------------------------------------------------------------
# Log function tests
# ---------------------------------------------------------------------------


class TestLogFunction(unittest.TestCase):
    """Test the _log function."""

    def setUp(self) -> None:
        self._capture = _LogCapture()
        config.logger.addHandler(self._capture)

    def tearDown(self) -> None:
        config.logger.removeHandler(self._capture)
        self._capture.records.clear()

    def test_log_format(self) -> None:
        _log('GET', '/tasks/1', 200)
        self.assertEqual(len(self._capture.records), 1)
        msg = self._capture.records[0].getMessage()
        self.assertIn('GET', msg)
        self.assertIn('/tasks/1', msg)
        self.assertIn('200', msg)

    def test_log_includes_client_ip(self) -> None:
        _log('GET', '/tasks/1', 200, '10.0.0.1')
        msg = self._capture.records[0].getMessage()
        self.assertIn('10.0.0.1', msg)
        self.assertIn('from', msg)


# ---------------------------------------------------------------------------
# Graceful shutdown tests
# ---------------------------------------------------------------------------


class TestGracefulShutdown(unittest.TestCase):
    """Test graceful shutdown signal handling."""

    def test_shutdown_handler_exists(self) -> None:
        self.assertTrue(hasattr(_shutdown, '__call__'))

    def test_shutdown_handler_calls_server_shutdown(self) -> None:
        """shutdown() is invoked off-handler (in a thread) — the handler thread
        calling it directly would deadlock against serve_forever()."""
        mock_server = MagicMock()
        _shutdown(mock_server, 0, None)
        for _ in range(100):
            if mock_server.shutdown.called:
                break
            time.sleep(0.02)
        mock_server.shutdown.assert_called_once()

    def test_shutdown_handler_does_not_block_caller(self) -> None:
        """A blocking shutdown() (real deadlock scenario) must not hang the
        signal handler — the handler returns immediately."""
        import threading as _threading
        started = _threading.Event()
        release = _threading.Event()

        def slow_shutdown() -> None:
            started.set()
            release.wait(5)

        mock_server = MagicMock()
        mock_server.shutdown.side_effect = slow_shutdown
        _shutdown(mock_server, 0, None)
        started.wait(2)
        release.set()
        mock_server.shutdown.assert_called_once()


# ---------------------------------------------------------------------------
# Handler method tests
# ---------------------------------------------------------------------------


class TestHandlerMethods(unittest.TestCase):
    """Test that the handler has all required HTTP method handlers."""

    def test_handler_is_http_base(self) -> None:
        from http.server import BaseHTTPRequestHandler
        self.assertTrue(issubclass(ProxyHandler, BaseHTTPRequestHandler))

    def test_get_method_exists(self) -> None:
        self.assertTrue(hasattr(ProxyHandler, 'do_GET'))

    def test_post_method_exists(self) -> None:
        self.assertTrue(hasattr(ProxyHandler, 'do_POST'))

    def test_patch_method_exists(self) -> None:
        self.assertTrue(hasattr(ProxyHandler, 'do_PATCH'))

    def test_delete_method_exists(self) -> None:
        self.assertTrue(hasattr(ProxyHandler, 'do_DELETE'))

    def test_put_method_exists(self) -> None:
        self.assertTrue(hasattr(ProxyHandler, 'do_PUT'))

    def test_log_message_method_exists(self) -> None:
        self.assertTrue(hasattr(ProxyHandler, 'log_message'))

    def test_send_json_method_exists(self) -> None:
        self.assertTrue(hasattr(ProxyHandler, '_send_json'))


class TestProxyRouting(unittest.TestCase):
    """Test _proxy() routing for every method and endpoint."""

    def setUp(self) -> None:
        """Isolate HEAD existence checks in a temporary tasks directory."""
        self.tmpdir = tempfile.mkdtemp()
        self._orig_tasks_dir = config.TASKS_DIR
        config.TASKS_DIR = self.tmpdir
        config.init_tasks_dir(self.tmpdir)

    def tearDown(self) -> None:
        config.TASKS_DIR = self._orig_tasks_dir
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _routed(self, method: str, path: str) -> tuple[ProxyHandler, list[str]]:
        """Run _proxy with all sub-handlers stubbed; return handler and call log."""
        handler = cast(Any, _make_handler())
        handler.path = path
        calls: list[str] = []
        handler._handle_tasks_list = lambda p: calls.append('tasks_list')
        handler._handle_task_get = lambda i: calls.append(f'task_get:{i}')
        handler._handle_task_create = lambda: calls.append('task_create')
        handler._handle_task_update = lambda i: calls.append(f'task_update:{i}')
        handler._handle_task_delete = lambda i: calls.append(f'task_delete:{i}')
        handler._handle_projects_list = lambda: calls.append('projects_list')
        handler._handle_projects_create = lambda: calls.append('projects_create')
        handler._handle_ui = lambda: calls.append('ui')
        handler._handle_static = lambda: calls.append('static')
        handler._proxy(method)
        return handler, calls

    # --- GET -------------------------------------------------------------------

    def test_get_tasks_list_routes(self) -> None:
        """GET /tasks should route to the tasks-list handler."""
        _, calls = self._routed('GET', '/tasks')
        self.assertEqual(calls, ['tasks_list'])

    def test_get_task_by_id_routes_with_parsed_id(self) -> None:
        """GET /tasks/{id} should pass the numeric id to the handler."""
        _, calls = self._routed('GET', '/tasks/42')
        self.assertEqual(calls, ['task_get:42'])

    def test_get_projects_routes(self) -> None:
        """GET /projects should route to the projects-list handler."""
        _, calls = self._routed('GET', '/projects')
        self.assertEqual(calls, ['projects_list'])

    def test_get_ui_routes(self) -> None:
        """GET /ui should route to the UI handler."""
        _, calls = self._routed('GET', '/ui')
        self.assertEqual(calls, ['ui'])

    def test_get_css_routes_to_static(self) -> None:
        """GET /css/* should route to the static handler."""
        _, calls = self._routed('GET', '/css/styles.css')
        self.assertEqual(calls, ['static'])

    def test_get_js_routes_to_static(self) -> None:
        """GET /js/* should route to the static handler."""
        _, calls = self._routed('GET', '/js/app.js')
        self.assertEqual(calls, ['static'])

    def test_get_query_params_passed_to_handler(self) -> None:
        """The parsed query string should reach the tasks-list handler."""
        handler = cast(Any, _make_handler())
        handler.path = '/tasks?project=p&status=open'
        seen: dict = {}
        handler._handle_tasks_list = lambda p: seen.update(p)
        handler._proxy('GET')
        self.assertEqual(seen.get('project'), ['p'])
        self.assertEqual(seen.get('status'), ['open'])

    # --- POST ------------------------------------------------------------------

    def test_post_tasks_routes(self) -> None:
        """POST /tasks should route to the task-create handler."""
        _, calls = self._routed('POST', '/tasks')
        self.assertEqual(calls, ['task_create'])

    def test_post_projects_routes(self) -> None:
        """POST /projects should route to the project-create handler."""
        _, calls = self._routed('POST', '/projects')
        self.assertEqual(calls, ['projects_create'])

    def test_post_on_non_collection_path_returns_404(self) -> None:
        """POST /ui (whitelisted but not a POST route) should return not found."""
        handler, calls = self._routed('POST', '/ui')
        self.assertEqual(calls, [])
        data = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])
        self.assertEqual(data['error'], 'not found')

    # --- PATCH / DELETE ----------------------------------------------------------

    def test_patch_task_routes_with_id(self) -> None:
        """PATCH /tasks/{id} should pass the parsed id."""
        _, calls = self._routed('PATCH', '/tasks/7')
        self.assertEqual(calls, ['task_update:7'])

    def test_patch_without_id_returns_404(self) -> None:
        """PATCH /tasks (no id) should return not found."""
        handler, calls = self._routed('PATCH', '/tasks')
        self.assertEqual(calls, [])
        data = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])
        self.assertEqual(data['error'], 'not found')

    def test_delete_task_routes_with_id(self) -> None:
        """DELETE /tasks/{id} should pass the parsed id."""
        _, calls = self._routed('DELETE', '/tasks/9')
        self.assertEqual(calls, ['task_delete:9'])

    def test_delete_without_id_returns_404(self) -> None:
        """DELETE /tasks (no id) should return not found."""
        handler, calls = self._routed('DELETE', '/tasks')
        self.assertEqual(calls, [])
        data = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])
        self.assertEqual(data['error'], 'not found')

    # --- HEAD --------------------------------------------------------------------

    def _head(self, path: str) -> tuple[int, str]:
        """Send a HEAD through _proxy; return (status, content-type)."""
        handler = cast(Any, _make_handler())
        handler.path = path
        status: dict = {}
        headers: dict = {}
        handler.send_response = lambda s: status.update(s=s)
        handler.send_header = lambda k, v: headers.update({k: v})
        handler.end_headers = lambda: None
        handler._proxy('HEAD')
        return status.get('s', 0), headers.get('Content-Type', '')

    def test_head_tasks_returns_200_json(self) -> None:
        """HEAD /tasks should return 200 with a JSON content-type and no body."""
        status, ct = self._head('/tasks')
        self.assertEqual(status, 200)
        self.assertEqual(ct, 'application/json')

    def test_head_ui_returns_200_html(self) -> None:
        """HEAD /ui should advertise the HTML content-type."""
        status, ct = self._head('/ui')
        self.assertEqual(status, 200)
        self.assertIn('text/html', ct)

    def test_head_css_returns_200_css_type(self) -> None:
        """HEAD /css/* should advertise the CSS content-type."""
        status, ct = self._head('/css/styles.css')
        self.assertEqual(status, 200)
        self.assertIn('text/css', ct)

    def test_head_js_returns_200_js_type(self) -> None:
        """HEAD /js/* should advertise the JavaScript content-type."""
        status, ct = self._head('/js/app.js')
        self.assertEqual(status, 200)
        self.assertIn('javascript', ct)

    def test_head_task_id_returns_200(self) -> None:
        """HEAD /tasks/{id} should return 200 for an existing task."""
        storage.create_task(title="Head me")
        status, _ = self._head('/tasks/1')
        self.assertEqual(status, 200)

    def test_head_task_id_mirrors_get_404(self) -> None:
        """Review 2.2 — HEAD on a missing task id must 404 like GET."""
        status, _ = self._head('/tasks/999')
        self.assertEqual(status, 404)

    def test_head_missing_css_returns_404(self) -> None:
        """HEAD on a missing static asset must 404 like GET."""
        status, _ = self._head('/css/does-not-exist.css')
        self.assertEqual(status, 404)

    def test_head_projects_returns_200(self) -> None:
        """HEAD /projects should return 200."""
        status, _ = self._head('/projects')
        self.assertEqual(status, 200)

    def test_head_blocked_path_returns_404(self) -> None:
        """HEAD on a non-whitelisted path should return a bare 404."""
        handler = cast(Any, _make_handler())
        handler.path = '/unknown'
        status: dict = {}
        handler.send_response = lambda s: status.update(s=s)
        handler.end_headers = lambda: None
        handler._proxy('HEAD')
        self.assertEqual(status.get('s'), 404)

    # --- methods -----------------------------------------------------------------

    def test_unsupported_method_returns_405(self) -> None:
        """PUT on a whitelisted path should return method not allowed."""
        handler, calls = self._routed('PUT', '/tasks')
        self.assertEqual(calls, [])
        data = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])
        self.assertEqual(data['error'], 'method not allowed')

    def test_http_methods_delegate_to_proxy(self) -> None:
        """Each do_* should call _proxy with its method name."""
        handler = cast(Any, _make_handler())
        handler.path = '/tasks'
        calls: list[str] = []
        handler._proxy = calls.append
        handler.do_GET()
        handler.do_HEAD()
        handler.do_POST()
        handler.do_PATCH()
        handler.do_PUT()
        handler.do_DELETE()
        self.assertEqual(calls, ['GET', 'HEAD', 'POST', 'PATCH', 'PUT', 'DELETE'])


class TestTaskUpdateEdgeCases(unittest.TestCase):
    """Test remaining handler edge cases."""

    def setUp(self) -> None:
        """Use a temporary tasks directory."""
        self.tmpdir = tempfile.mkdtemp()
        self._orig_tasks_dir = config.TASKS_DIR
        config.TASKS_DIR = self.tmpdir
        config.init_tasks_dir(self.tmpdir)

    def tearDown(self) -> None:
        """Restore the tasks directory."""
        config.TASKS_DIR = self._orig_tasks_dir
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_patch_invalid_json_returns_400(self) -> None:
        """PATCH with an unparseable body should return 400."""
        handler = cast(Any, _make_handler())
        handler.path = '/tasks/1'
        raw = b'nope{{}'
        del handler.headers['Content-Length']  # HTTPMessage assignment appends, not replaces
        handler.headers['Content-Length'] = str(len(raw))
        handler.rfile = io.BytesIO(raw)
        handler._handle_task_update(1)
        data = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])
        self.assertEqual(data['error'], 'invalid JSON body')

    def test_task_create_defaults(self) -> None:
        """Creating with only a title should apply documented defaults."""
        handler = cast(Any, _make_handler())
        handler.path = '/tasks'
        body = json.dumps({'title': 'Minimal'}).encode()
        del handler.headers['Content-Length']
        handler.headers['Content-Length'] = str(len(body))
        handler.rfile = io.BytesIO(body)
        handler._handle_task_create()
        task = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])['task']
        self.assertEqual(task['project'], 'default')
        self.assertEqual(task['status'], 'open')
        self.assertEqual(task['priority'], 'medium')

    def _write_raw_task(self, rel: str, content: str) -> None:
        """Plant a hand-written task file (bypassing storage validation)."""
        path = os.path.join(config.TASKS_DIR, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'w') as f:
            f.write(content)

    def test_update_backfills_missing_created_at(self) -> None:
        """PATCH on a hand-edited file without created_at must not crash."""
        self._write_raw_task(
            'default/001_hand.md',
            '---\nid: 1\ntitle: "hand"\nstatus: open\npriority: medium\ndue_date:\ntags: []\n---\n',
        )
        task = storage.update_task(1, {'status': 'done'})
        self.assertIsNotNone(task)
        assert task is not None
        self.assertEqual(task['status'], 'done')
        self.assertTrue(task['created_at'])

    def test_update_backfills_missing_title_status_priority(self) -> None:
        """Frontmatter missing title/status/priority gets safe fallbacks."""
        self._write_raw_task('default/002_bare-bones.md', '---\nid: 2\n---\n')
        task = storage.update_task(2, {'description': 'x'})
        self.assertIsNotNone(task)
        assert task is not None
        self.assertEqual(task['title'], 'bare bones')
        self.assertEqual(task['status'], 'open')
        self.assertEqual(task['priority'], 'medium')
        self.assertEqual(task['id'], 2)
        self.assertTrue(task['created_at'])

    def test_update_backfills_missing_id_from_path(self) -> None:
        """A file without an id key gets the id the URL asked for."""
        self._write_raw_task('default/004_no-id.md', '---\ntitle: "No Id"\n---\n')
        task = storage.update_task(4, {'status': 'done'})
        self.assertIsNotNone(task)
        assert task is not None
        self.assertEqual(task['id'], 4)
        self.assertEqual(task['status'], 'done')


class TestStorageEdgeCases(unittest.TestCase):
    """Test uncovered storage-layer branches."""

    def setUp(self) -> None:
        """Use a temporary tasks directory."""
        self.tmpdir = tempfile.mkdtemp()
        self._orig_tasks_dir = config.TASKS_DIR
        config.TASKS_DIR = self.tmpdir
        config.init_tasks_dir(self.tmpdir)

    def tearDown(self) -> None:
        """Restore the tasks directory."""
        config.TASKS_DIR = self._orig_tasks_dir
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    # --- _parse_value -------------------------------------------------------------

    def test_parse_value_null_and_empty(self) -> None:
        """Empty and 'null' strings should parse to None."""
        self.assertIsNone(storage._parse_value(''))
        self.assertIsNone(storage._parse_value('null'))
        self.assertIsNone(storage._parse_value('NULL'))

    def test_parse_value_booleans(self) -> None:
        """true/false (any case) should parse to booleans."""
        self.assertIs(storage._parse_value('true'), True)
        self.assertIs(storage._parse_value('False'), False)

    def test_parse_value_float(self) -> None:
        """A decimal value should parse to float."""
        self.assertEqual(storage._parse_value('3.5'), 3.5)

    # --- frontmatter round-trips ----------------------------------------------------

    def test_parse_frontmatter_blank_line_and_explicit_none(self) -> None:
        """Blank lines are skipped and 'key: None' parses to None."""
        content = '---\nid: 1\n\ndue_date: None\nflag: true\n---\nbody\n'
        fm, body = storage.parse_frontmatter(content)
        self.assertIsNone(fm['due_date'])
        self.assertIs(fm['flag'], True)
        self.assertEqual(body.strip(), 'body')

    def test_format_frontmatter_boolean(self) -> None:
        """Booleans should serialize as lowercase true/false."""
        text = storage.format_frontmatter({'a': True, 'b': False})
        self.assertIn('a: true', text)
        self.assertIn('b: false', text)

    def test_bool_roundtrip(self) -> None:
        """A bool field should survive format → parse unchanged."""
        text = storage.format_frontmatter({'flag': False})
        fm, _ = storage.parse_frontmatter(f'---\n{text}\n---\n')
        self.assertIs(fm['flag'], False)

    # --- helpers ---------------------------------------------------------------------
    # (the former _task_file_path/_internal_keys helpers were removed as dead code;
    #  create_task/update_task build paths inline through _ensure_project_dir)

    def test_ensure_project_dir_rejects_traversal(self) -> None:
        """Names that could escape TASKS_DIR raise ValueError at the choke point."""
        for bad in ('../escape', '/tmp/abs', '..', '.', '.hidden', 'a/b', ''):
            with self.assertRaises(ValueError):
                storage._ensure_project_dir(bad)

    def test_ensure_project_dir_accepts_normal_names(self) -> None:
        for good in ('default', 'my-project', 'my_project', 'a.b c', 'Proj1'):
            storage._ensure_project_dir(good)
            self.assertTrue(os.path.isdir(os.path.join(self.tmpdir, good)))

    def test_valid_project_name(self) -> None:
        self.assertTrue(storage.valid_project_name('agent-tools'))
        self.assertFalse(storage.valid_project_name('../x'))
        self.assertFalse(storage.valid_project_name('a/b'))
        self.assertFalse(storage.valid_project_name('/abs'))
        self.assertFalse(storage.valid_project_name('..'))
        self.assertFalse(storage.valid_project_name('.hidden'))
        self.assertFalse(storage.valid_project_name(None))

    def test_list_tasks_traversal_filter_returns_empty(self) -> None:
        """A traversal-laden project filter must not scan outside TASKS_DIR."""
        self.assertEqual(storage.list_tasks(project='../../etc'), [])

    def test_list_tasks_finds_four_digit_ids(self) -> None:
        """Once the counter rolls past 999 the files must still be listed."""
        os.makedirs(os.path.join(self.tmpdir, 'default'))
        with open(os.path.join(self.tmpdir, 'default', '1000_rolled-over.md'), 'w') as f:
            f.write('---\nid: 1000\ntitle: big\nstatus: open\n---\n')
        tasks = storage.list_tasks()
        self.assertEqual([t['id'] for t in tasks], [1000])

    # --- scanning robustness ------------------------------------------------------------

    def _write_stray_file(self) -> None:
        """Create a project with one real task and one non-task file."""
        storage.create_task(title='Real task', project='proj')
        with open(os.path.join(self.tmpdir, 'proj', 'README.md'), 'w') as f:
            f.write('not a task\n')

    def test_list_tasks_skips_non_task_files(self) -> None:
        """Non-task files inside a project dir must not break listing."""
        self._write_stray_file()
        tasks = storage.list_tasks()
        self.assertEqual(len(tasks), 1)
        self.assertEqual(tasks[0]['title'], 'Real task')

    def test_list_tasks_missing_project_returns_empty(self) -> None:
        """Filtering by a nonexistent project should return no tasks."""
        storage.create_task(title='T', project='proj')
        self.assertEqual(storage.list_tasks(project='ghost'), [])

    def test_get_task_skips_non_task_files(self) -> None:
        """get_task must ignore stray files when scanning."""
        self._write_stray_file()
        task = storage.get_task(1)
        self.assertIsNotNone(task)
        self.assertEqual(task['title'], 'Real task')  # type: ignore[index]

    def test_delete_task_skips_non_task_files(self) -> None:
        """delete_task must ignore stray files and still find the task."""
        self._write_stray_file()
        self.assertTrue(storage.delete_task(1))
        self.assertIsNone(storage.get_task(1))

    def test_delete_nonexistent_id_with_stray_files_returns_false(self) -> None:
        """Deleting an absent id must skip every scanned file and report False."""
        self._write_stray_file()
        self.assertFalse(storage.delete_task(99))
        self.assertIsNotNone(storage.get_task(1))


class TestRequestBodyValidation(unittest.TestCase):
    """4.1 — malformed body/metadata answers 400, never a crashed handler."""

    def _handler_with_body(self, body: bytes) -> ProxyHandler:
        handler = _make_handler()
        handler.rfile = io.BytesIO(body)
        handler.headers.replace_header('Content-Length', str(len(body)))
        return handler

    def _call(self, handler: ProxyHandler, invoke: Any) -> tuple[int, dict]:
        sent: list[tuple[int, dict]] = []

        def _send(status: int, data: dict | list) -> None:
            sent.append((status, data))  # type: ignore[arg-type]

        handler._send_json = _send  # type: ignore[method-assign]
        invoke(handler)
        self.assertEqual(len(sent), 1)
        return sent[0]

    def test_non_object_json_bodies_rejected(self) -> None:
        """Valid JSON that is not an object must 400 on every body endpoint."""
        for raw in (b'5', b'"str"', b'[1, 2]', b'true', b'null'):
            for invoke in (
                lambda h: h._handle_task_create(),
                lambda h: h._handle_task_update(1),
                lambda h: h._handle_projects_create(),
            ):
                status, body = self._call(self._handler_with_body(raw), invoke)
                self.assertEqual(status, 400, raw)
                self.assertEqual(body['error'], 'body must be a JSON object', raw)

    def test_invalid_content_length_rejected(self) -> None:
        """A non-numeric Content-Length must 400, not crash the handler."""
        for invoke in (
            lambda h: h._handle_task_create(),
            lambda h: h._handle_task_update(1),
            lambda h: h._handle_projects_create(),
        ):
            handler = _make_handler()
            handler.headers.replace_header('Content-Length', 'not-a-number')
            status, body = self._call(handler, invoke)
            self.assertEqual(status, 400)
            self.assertEqual(body['error'], 'invalid Content-Length header')

    def test_negative_content_length_rejected(self) -> None:
        """A negative Content-Length must 400, not read until EOF."""
        for invoke in (
            lambda h: h._handle_task_create(),
            lambda h: h._handle_task_update(1),
            lambda h: h._handle_projects_create(),
        ):
            handler = _make_handler()
            handler.headers.replace_header('Content-Length', '-5')
            status, body = self._call(handler, invoke)
            self.assertEqual(status, 400)
            self.assertEqual(body['error'], 'invalid Content-Length header')

    def test_object_body_still_accepted(self) -> None:
        """The guard must not break the normal path."""
        self.tmpdir = tempfile.mkdtemp()
        self._orig_tasks_dir = config.TASKS_DIR
        config.TASKS_DIR = self.tmpdir
        config.init_tasks_dir(self.tmpdir)
        try:
            status, body = self._call(
                self._handler_with_body(b'{"title": "still fine"}'),
                lambda h: h._handle_task_create(),
            )
            self.assertEqual(status, 201)
            self.assertEqual(body['task']['title'], 'still fine')
        finally:
            config.TASKS_DIR = self._orig_tasks_dir
            import shutil
            shutil.rmtree(self.tmpdir, ignore_errors=True)


class TestLongTitlesAndEscapes(unittest.TestCase):
    """5.1/5.2 — long titles and special characters never break the write path."""

    def setUp(self) -> None:
        self.tmpdir = tempfile.mkdtemp()
        self._orig_tasks_dir = config.TASKS_DIR
        config.TASKS_DIR = self.tmpdir
        config.init_tasks_dir(self.tmpdir)

    def tearDown(self) -> None:
        config.TASKS_DIR = self._orig_tasks_dir
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _read(self, task_id: int) -> dict:
        task = storage.get_task(task_id)
        self.assertIsNotNone(task)
        assert task is not None
        return task

    def test_create_task_long_title_clamped(self) -> None:
        """A 300-char title must create fine — the filename slug is clamped."""
        task = storage.create_task(title='a' * 300)
        self.assertLessEqual(len(task['filename']), 90)
        self.assertTrue(os.path.exists(os.path.join(self.tmpdir, 'default', task['filename'])))
        self.assertEqual(self._read(task['id'])['title'], 'a' * 300)

    def test_update_task_long_title_clamped(self) -> None:
        """Renaming to a 300-char title must move the file, not crash it."""
        task = storage.create_task(title='Short')
        updated = storage.update_task(task['id'], {'title': 'b' * 300})
        self.assertIsNotNone(updated)
        assert updated is not None
        self.assertLessEqual(len(updated['filename']), 90)
        self.assertTrue(os.path.exists(os.path.join(self.tmpdir, 'default', updated['filename'])))
        self.assertFalse(os.path.exists(os.path.join(self.tmpdir, 'default', '001_short.md')))
        self.assertEqual(self._read(task['id'])['title'], 'b' * 300)

    def test_title_with_newline_roundtrips(self) -> None:
        """A newline in the title must survive the frontmatter write/read."""
        task = storage.create_task(title='line one\nline two')
        self.assertEqual(self._read(task['id'])['title'], 'line one\nline two')

    def test_title_with_quotes_roundtrips(self) -> None:
        """Quotes in the title must survive the frontmatter write/read."""
        task = storage.create_task(title='He said "hi"')
        self.assertEqual(self._read(task['id'])['title'], 'He said "hi"')

    def test_tags_with_quotes_roundtrip(self) -> None:
        """A quote inside a tag must not merge or truncate it on read-back."""
        task = storage.create_task(title='Tags', tags=['a"b', 'plain'])
        self.assertEqual(self._read(task['id'])['tags'], ['a"b', 'plain'])

    def test_legacy_unquoted_frontmatter_still_parses(self) -> None:
        """Hand-written files keep the lenient parse path."""
        project = os.path.join(self.tmpdir, 'legacy')
        os.makedirs(project)
        with open(os.path.join(project, '001_legacy.md'), 'w') as f:
            f.write('---\nid: 1\ntitle: "old" style"\nstatus: open\ntags: [a, b]\n---\n')
        task = storage.get_task(1)
        self.assertIsNotNone(task)
        assert task is not None
        self.assertEqual(task['title'], 'old" style')
        self.assertEqual(task['tags'], ['a', 'b'])


class TestUnreadableTaskFiles(unittest.TestCase):
    """6.3 — one odd task file must never take down a read endpoint."""

    def setUp(self) -> None:
        self.tmpdir = tempfile.mkdtemp()
        self._orig_tasks_dir = config.TASKS_DIR
        config.TASKS_DIR = self.tmpdir
        config.init_tasks_dir(self.tmpdir)
        storage.create_task(title='Healthy task', project='demo')

    def tearDown(self) -> None:
        config.TASKS_DIR = self._orig_tasks_dir
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_non_utf8_file_is_survivable(self) -> None:
        """A cp1252 byte in a task file must not raise UnicodeDecodeError."""
        with open(os.path.join(self.tmpdir, 'demo', '002_cafe.md'), 'wb') as f:
            f.write('---\nid: 2\ntitle: caf'.encode('utf-8') + b'\xe9\n---\n')
        tasks = storage.list_tasks()
        self.assertEqual(len(tasks), 2)
        self.assertIsNotNone(storage.get_task(2))

    def test_directory_named_like_task_is_skipped(self) -> None:
        """A directory named NNN_x.md must be skipped, not IsADirectoryError."""
        os.makedirs(os.path.join(self.tmpdir, 'demo', '009_dir.md'))
        tasks = storage.list_tasks()
        self.assertEqual([t['id'] for t in tasks], [1])
        self.assertIsNone(storage.get_task(9))

    def test_dangling_symlink_is_skipped(self) -> None:
        """A symlink to a removed file (or a concurrent DELETE) must not 000."""
        os.symlink(
            os.path.join(self.tmpdir, 'demo', 'gone.md'),
            os.path.join(self.tmpdir, 'demo', '008_dangling.md'),
        )
        tasks = storage.list_tasks()
        self.assertEqual([t['id'] for t in tasks], [1])
        self.assertIsNone(storage.get_task(8))

    def test_delete_survives_vanished_file(self) -> None:
        """Deleting a task whose file already vanished answers False, no crash."""
        storage.create_task(title='Doomed', project='demo')
        os.remove(os.path.join(self.tmpdir, 'demo', '002_doomed.md'))
        self.assertFalse(storage.delete_task(2))


class TestProjectDirPreserved(unittest.TestCase):
    """6.8 — deleting/moving a task never removes the project directory."""

    def setUp(self) -> None:
        self.tmpdir = tempfile.mkdtemp()
        self._orig_tasks_dir = config.TASKS_DIR
        config.TASKS_DIR = self.tmpdir
        config.init_tasks_dir(self.tmpdir)

    def tearDown(self) -> None:
        config.TASKS_DIR = self._orig_tasks_dir
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_delete_last_task_keeps_project(self) -> None:
        storage.create_project('solo')
        storage.create_task(title='Only one', project='solo')
        self.assertTrue(storage.delete_task(1))
        self.assertIn('solo', storage.list_projects())
        self.assertTrue(os.path.isdir(os.path.join(self.tmpdir, 'solo')))

    def test_move_out_leaves_source_project(self) -> None:
        storage.create_task(title='Mover', project='alpha')
        storage.update_task(1, {'project': 'beta'})
        self.assertIn('alpha', storage.list_projects())
        self.assertTrue(os.path.isdir(os.path.join(self.tmpdir, 'alpha')))


class TestDueDateFormat(unittest.TestCase):
    """6.1 — due_date is validated as YYYY-MM-DD (kills the raw-interpolation XSS vector)."""

    def _post(self, body: dict) -> tuple[int, dict]:
        self.tmpdir = tempfile.mkdtemp()
        self._orig_tasks_dir = config.TASKS_DIR
        config.TASKS_DIR = self.tmpdir
        config.init_tasks_dir(self.tmpdir)
        try:
            handler = _make_handler()
            raw = json.dumps(body).encode()
            handler.rfile = io.BytesIO(raw)
            handler.headers.replace_header('Content-Length', str(len(raw)))
            sent: list[tuple[int, dict]] = []
            handler._send_json = lambda s, d: sent.append((s, d))  # type: ignore[method-assign]
            handler._handle_task_create()
            return sent[0]
        finally:
            config.TASKS_DIR = self._orig_tasks_dir
            import shutil
            shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_xss_payload_rejected(self) -> None:
        status, body = self._post({'title': 'x', 'due_date': '"><img id=injected src=x onerror=document.title=1>'})
        self.assertEqual(status, 400)
        self.assertEqual(body['error'], 'due_date must be a YYYY-MM-DD string or null')

    def test_non_iso_date_rejected(self) -> None:
        status, body = self._post({'title': 'x', 'due_date': '15-08-2026'})
        self.assertEqual(status, 400)

    def test_valid_date_accepted(self) -> None:
        status, body = self._post({'title': 'x', 'due_date': '2026-08-15'})
        self.assertEqual(status, 201)
        self.assertEqual(body['task']['due_date'], '2026-08-15')

    def test_patch_bad_date_rejected(self) -> None:
        handler = _make_handler()
        raw = json.dumps({'due_date': 'tomorrow'}).encode()
        handler.rfile = io.BytesIO(raw)
        handler.headers.replace_header('Content-Length', str(len(raw)))
        sent: list[tuple[int, dict]] = []
        handler._send_json = lambda s, d: sent.append((s, d))  # type: ignore[method-assign]
        handler._handle_task_update(1)
        self.assertEqual(sent[0][0], 400)
        self.assertEqual(sent[0][1]['error'], 'due_date must be a YYYY-MM-DD string or null')

    def test_due_date_with_quotes_roundtrips_in_storage(self) -> None:
        """Storage-level: the JSON-escaping writer keeps odd due_date values intact."""
        self.tmpdir = tempfile.mkdtemp()
        self._orig_tasks_dir = config.TASKS_DIR
        config.TASKS_DIR = self.tmpdir
        config.init_tasks_dir(self.tmpdir)
        try:
            storage.create_task(title='q', due_date='x"y\\z')
            task = storage.get_task(1)
            self.assertIsNotNone(task)
            assert task is not None
            self.assertEqual(task['due_date'], 'x"y\\z')
        finally:
            config.TASKS_DIR = self._orig_tasks_dir
            import shutil
            shutil.rmtree(self.tmpdir, ignore_errors=True)


class TestUiEscaping(unittest.TestCase):
    """6.1 — the UI must escape attribute/JS contexts holding task data."""

    @classmethod
    def setUpClass(cls) -> None:
        ui_js = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'ui', 'js', 'app.js'
        )
        with open(ui_js, 'r') as f:
            cls.src = f.read()

    def test_no_raw_task_data_in_value_attributes(self) -> None:
        self.assertNotIn('value="${task.', self.src)
        self.assertNotIn("value=\"${task.", self.src)

    def test_attribute_contexts_use_escape_attr(self) -> None:
        self.assertIn('function escapeAttr', self.src)
        self.assertIn('value="${escapeAttr(task.title)}"', self.src)
        self.assertIn("value=\"${escapeAttr(task.due_date || '')}\"", self.src)

    def test_inline_js_arg_is_json_encoded(self) -> None:
        """Tag removal must not smuggle a quote out of the inline handler."""
        self.assertIn('removeTag(${escapeAttr(JSON.stringify(tag))})', self.src)
        self.assertNotIn("removeTag('${escapeHtml(tag)}')", self.src)

    def test_markdown_links_have_scheme_allowlist(self) -> None:
        self.assertIn('function isSafeHref', self.src)
        self.assertIn('isSafeHref(url)', self.src)
        self.assertNotIn("'<a href=\"$2\"", self.src)

    def test_badges_escape_their_label(self) -> None:
        """7.1 — both badges interpolate the value; both must escape it."""
        self.assertIn("${escapeAttr(s || 'open')}", self.src)
        self.assertIn("${escapeAttr(p || 'medium')}", self.src)
        self.assertNotIn("${s || 'open'}", self.src)
        self.assertNotIn("${p || 'medium'}", self.src)

    def test_update_field_reports_failed_patches(self) -> None:
        """7.3 — a failed PATCH must toast and reload, like every other mutation."""
        self.assertIn('Failed to update ${field}', self.src)
        self.assertIn("toast(data.error || `Failed to update ${field}`, true)", self.src)

    def test_default_project_option_is_conditional(self) -> None:
        """8.2 — the hardcoded 'default' option must not duplicate a real project."""
        # The two dropdowns that can show 'default' must gate on whether the
        # dynamic list already contains it.
        self.assertGreaterEqual(self.src.count("projects.includes('default')"), 2)
        # Each occurrence must sit inside a ternary that omits the option when
        # 'default' is already present.
        for site in ('create modal', 'detail panel'):
            with self.subTest(site=site):
                pass  # The count + the source rewrite below are the guard.
        # Verify the default option is generated into a local rather than an
        # unconditional trailing append.
        self.assertIn("projects.includes('default') ? '' :", self.src)


class TestStaticQueryStringHandling(unittest.TestCase):
    """6.5 — GET must open the query-stripped file, mirroring HEAD."""

    def _get_status(self, path: str) -> int:
        handler = cast(Any, _make_handler())
        handler.path = path
        status: dict = {}
        handler.send_response = lambda s: status.update(s=s)
        handler.send_header = lambda k, v: None
        handler.end_headers = lambda: None
        handler.wfile.write = lambda data: None
        handler._proxy('GET')
        return status.get('s', 0)

    def _head_status(self, path: str) -> int:
        handler = cast(Any, _make_handler())
        handler.path = path
        status: dict = {}
        handler.send_response = lambda s: status.update(s=s)
        handler.send_header = lambda k, v: None
        handler.end_headers = lambda: None
        handler._proxy('HEAD')
        return status.get('s', 0)

    def test_css_with_cache_busting_query_is_served(self) -> None:
        self.assertEqual(self._get_status('/css/styles.css?v=2'), 200)

    def test_missing_css_with_query_is_404(self) -> None:
        self.assertEqual(self._get_status('/css/does-not-exist.css?v=2'), 404)

    def test_head_and_get_agree_on_queried_asset(self) -> None:
        self.assertEqual(self._head_status('/css/styles.css?v=2'), self._get_status('/css/styles.css?v=2'))
        self.assertEqual(self._head_status('/css/nope.css?v=2'), self._get_status('/css/nope.css?v=2'))

    def test_head_tasks_bad_project_filter_mirrors_get_400(self) -> None:
        """6.7 — HEAD mirrors GET's 400 for an unsafe project filter."""
        self.assertEqual(self._head_status('/tasks?project=../etc'), 400)


class TestPass6Documentation(unittest.TestCase):
    """Guardrails for the gate-script interpreter name (6.10)."""

    def test_gate_scripts_use_python3(self) -> None:
        scripts_dir = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'scripts'
        )
        for name in ('test-project.sh', 'lint-project.sh', 'coverage-project.sh'):
            with open(os.path.join(scripts_dir, name)) as f:
                src = f.read()
            self.assertNotIn('python -m', src, name)
            self.assertNotIn('python -c', src, name)


class TestProjectNameCollision(unittest.TestCase):
    """9.1 — a project name colliding with a plain file in TASKS_DIR is a 400, not a dropped connection."""

    def setUp(self) -> None:
        self.tmpdir = tempfile.mkdtemp()
        self._orig_tasks_dir = config.TASKS_DIR
        config.TASKS_DIR = self.tmpdir
        config.init_tasks_dir(self.tmpdir)
        with open(os.path.join(self.tmpdir, 'alpha'), 'w') as f:
            f.write('stray file on a hand-managed volume\n')

    def tearDown(self) -> None:
        config.TASKS_DIR = self._orig_tasks_dir
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _invoke(self, handler_method: Any, body: dict) -> tuple[int, dict]:
        handler = _make_handler()
        raw = json.dumps(body).encode()
        handler.rfile = io.BytesIO(raw)
        handler.headers.replace_header('Content-Length', str(len(raw)))
        sent: list[tuple[int, dict]] = []
        handler._send_json = lambda s, d: sent.append((s, d))  # type: ignore[method-assign]
        handler_method(handler)
        return sent[0]

    def test_post_task_onto_file_collision_is_400(self) -> None:
        status, body = self._invoke(lambda h: h._handle_task_create(), {'title': 'probe', 'project': 'alpha'})
        self.assertEqual(status, 400)
        self.assertIn('exists as a non-directory', body['error'])
        self.assertEqual(storage.list_tasks(), [])
        self.assertTrue(os.path.isfile(os.path.join(self.tmpdir, 'alpha')))

    def test_post_project_collision_is_400(self) -> None:
        status, body = self._invoke(lambda h: h._handle_projects_create(), {'name': 'alpha'})
        self.assertEqual(status, 400)
        self.assertIn('exists as a non-directory', body['error'])

    def test_patch_move_collision_is_400(self) -> None:
        storage.create_task(title='Mover', project='default')
        status, body = self._invoke(lambda h: h._handle_task_update(1), {'project': 'alpha'})
        self.assertEqual(status, 400)
        self.assertIn('exists as a non-directory', body['error'])
        task = storage.get_task(1)
        assert task is not None
        self.assertEqual(task['project'], 'default')
        self.assertTrue(os.path.isfile(os.path.join(self.tmpdir, 'alpha')))

    def test_fresh_and_existing_project_names_still_work(self) -> None:
        status, _ = self._invoke(lambda h: h._handle_task_create(), {'title': 'fresh', 'project': 'beta'})
        self.assertEqual(status, 201)
        storage.create_project('gamma')
        status, _ = self._invoke(lambda h: h._handle_task_create(), {'title': 'again', 'project': 'gamma'})
        self.assertEqual(status, 201)


class TestDueDateCalendar(unittest.TestCase):
    """9.2 — the due_date gate requires a real calendar date, not just the YYYY-MM-DD shape."""

    def setUp(self) -> None:
        self.tmpdir = tempfile.mkdtemp()
        self._orig_tasks_dir = config.TASKS_DIR
        config.TASKS_DIR = self.tmpdir
        config.init_tasks_dir(self.tmpdir)

    def tearDown(self) -> None:
        config.TASKS_DIR = self._orig_tasks_dir
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _post(self, body: dict) -> tuple[int, dict]:
        handler = _make_handler()
        raw = json.dumps(body).encode()
        handler.rfile = io.BytesIO(raw)
        handler.headers.replace_header('Content-Length', str(len(raw)))
        sent: list[tuple[int, dict]] = []
        handler._send_json = lambda s, d: sent.append((s, d))  # type: ignore[method-assign]
        handler._handle_task_create()
        return sent[0]

    def _patch(self, body: dict) -> tuple[int, dict]:
        storage.create_task(title='Date task')
        handler = _make_handler()
        raw = json.dumps(body).encode()
        handler.rfile = io.BytesIO(raw)
        handler.headers.replace_header('Content-Length', str(len(raw)))
        sent: list[tuple[int, dict]] = []
        handler._send_json = lambda s, d: sent.append((s, d))  # type: ignore[method-assign]
        handler._handle_task_update(1)
        return sent[0]

    def test_post_feb_30_rejected(self) -> None:
        status, body = self._post({'title': 'x', 'due_date': '2030-02-30'})
        self.assertEqual(status, 400)
        self.assertEqual(body['error'], 'due_date must be a YYYY-MM-DD string or null')
        self.assertEqual(storage.list_tasks(), [])

    def test_post_month_13_rejected(self) -> None:
        status, _ = self._post({'title': 'x', 'due_date': '2030-13-01'})
        self.assertEqual(status, 400)

    def test_post_leap_day_accepted(self) -> None:
        status, body = self._post({'title': 'x', 'due_date': '2028-02-29'})
        self.assertEqual(status, 201)
        self.assertEqual(body['task']['due_date'], '2028-02-29')

    def test_patch_impossible_date_rejected(self) -> None:
        status, body = self._patch({'due_date': '2030-02-30'})
        self.assertEqual(status, 400)
        self.assertEqual(body['error'], 'due_date must be a YYYY-MM-DD string or null')

    def test_patch_leap_day_accepted(self) -> None:
        status, body = self._patch({'due_date': '2028-02-29'})
        self.assertEqual(status, 200)
        self.assertEqual(body['task']['due_date'], '2028-02-29')


if __name__ == '__main__':
    unittest.main()
