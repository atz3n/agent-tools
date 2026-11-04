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
        mock_server = MagicMock()
        _shutdown(mock_server, 0, None)
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


if __name__ == '__main__':
    unittest.main()
