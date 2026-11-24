#!/usr/bin/env python3
"""Tests for the Odoo proxy server."""

from __future__ import annotations

import http.client
import io
import json
import logging
import os
import time
import unittest
from typing import cast
from unittest.mock import MagicMock, patch
from urllib.parse import parse_qs

from odoo_proxy import (
    config,  # noqa: E402
    session,  # noqa: E402
    whitelist,  # noqa: E402
)
from odoo_proxy import server as _server  # noqa: E402
from odoo_proxy.server import ProxyHandler, _log, _shutdown  # noqa: E402


class _LogCapture(logging.Handler):
    """Captures log records for testing."""

    def __init__(self) -> None:
        super().__init__()
        self.records: list[logging.LogRecord] = []

    def emit(self, record: logging.LogRecord) -> None:
        self.records.append(record)


class TestEndpointWhitelist(unittest.TestCase):
    """Test the endpoint whitelist."""

    def test_task_data_allowed(self) -> None:
        """GET /task/data should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/task/data'))

    def test_task_data_with_query_allowed(self) -> None:
        """GET /task/data?id=3807 should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/task/data?id=3807'))

    def test_task_messages_allowed(self) -> None:
        """GET /task/messages should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/task/messages'))

    def test_task_messages_with_query_allowed(self) -> None:
        """GET /task/messages?id=3807 should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/task/messages?id=3807'))

    def test_task_messages_with_multiple_params_allowed(self) -> None:
        """GET /task/messages?id=3807&limit=10 should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/task/messages?id=3807&limit=10'))

    def test_task_message_allowed(self) -> None:
        """POST /task/message should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/task/message'))

    def test_task_message_with_query_allowed(self) -> None:
        """POST /task/message?id=3807 should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/task/message?id=3807'))


class TestBlockedEndpoints(unittest.TestCase):
    """Test that non-ticket endpoints are properly rejected."""

    def test_root_blocked(self) -> None:
        """GET / should be rejected."""
        self.assertFalse(whitelist.is_allowed_endpoint('/'))

    def test_web_login_blocked(self) -> None:
        """GET /web/login should be rejected."""
        self.assertFalse(whitelist.is_allowed_endpoint('/web/login'))

    def test_web_dataset_blocked(self) -> None:
        """POST /web/dataset/call_kw should be rejected."""
        self.assertFalse(whitelist.is_allowed_endpoint('/web/dataset/call_kw/project.task/web_read'))

    def test_mail_thread_blocked(self) -> None:
        """POST /mail/thread/messages should be rejected."""
        self.assertFalse(whitelist.is_allowed_endpoint('/mail/thread/messages'))

    def test_mail_message_post_blocked(self) -> None:
        """The real Odoo note-posting route must not be reachable through the proxy."""
        self.assertFalse(whitelist.is_allowed_endpoint('/mail/message/post'))

    def test_arbitrary_path_blocked(self) -> None:
        """GET /foo should be rejected."""
        self.assertFalse(whitelist.is_allowed_endpoint('/foo'))

    def test_health_check_blocked(self) -> None:
        """GET /health should be rejected."""
        self.assertFalse(whitelist.is_allowed_endpoint('/health'))

    def test_api_prefix_blocked(self) -> None:
        """GET /api should be rejected."""
        self.assertFalse(whitelist.is_allowed_endpoint('/api'))

    def test_task_extra_segment_blocked(self) -> None:
        """GET /task/extra should be rejected."""
        self.assertFalse(whitelist.is_allowed_endpoint('/task/extra'))

    def test_task_data_subpath_blocked(self) -> None:
        """GET /task/data/extra should be rejected."""
        self.assertFalse(whitelist.is_allowed_endpoint('/task/data/extra'))


class TestConfiguration(unittest.TestCase):
    """Test configuration loading."""

    def test_default_port(self) -> None:
        """Default PORT should be 8087."""
        self.assertEqual(config.PORT, 8087)

    def test_custom_port_from_env(self) -> None:
        """PORT should be configurable via PROXY_PORT env var."""
        with patch.dict(os.environ, {'PROXY_PORT': '9999'}):
            # PORT is evaluated at module import time, so we need to reload
            import importlib
            importlib.reload(config)
            self.assertEqual(config.PORT, 9999)
            # Restore original
            patch.dict(os.environ, {'PROXY_PORT': '8087'}).start()
            self.addCleanup(lambda: importlib.reload(config))

    def test_empty_session_timeout_falls_back_to_default(self) -> None:
        """6.9 — ODOO_SESSION_TIMEOUT set-but-empty must default to 2700, not kill import."""
        with patch.dict(os.environ, {'ODOO_SESSION_TIMEOUT': ''}):
            import importlib
            importlib.reload(config)
            self.assertEqual(config.SESSION_TIMEOUT, 2700)
            self.addCleanup(lambda: importlib.reload(config))


class TestSecretLoading(unittest.TestCase):
    """Test reading secrets from environment variables."""

    def _set_all_env(self) -> None:
        """Set all required environment variables."""
        patch.dict(os.environ, {
            'ODOO_DB': 'test-db',
            'ODOO_URL': 'https://test.odoo.com',
            'ODOO_USER': 'test@example.com',
            'ODOO_PASSWORD': 'secret123',
        }).start()
        self.addCleanup(patch.stopall)

    def test_load_config_success(self) -> None:
        """load_config should return config dict when all env vars are set."""
        self._set_all_env()

        import importlib
        importlib.reload(config)
        conf = config.load_config()
        self.assertEqual(conf['db'], 'test-db')
        self.assertEqual(conf['url'], 'https://test.odoo.com')
        self.assertEqual(conf['user'], 'test@example.com')
        self.assertEqual(conf['password'], 'secret123')

    def test_load_config_missing_env_var(self) -> None:
        """load_config should exit when an env var is missing."""
        patch.dict(os.environ, {
            'ODOO_DB': 'test-db',
            'ODOO_URL': 'https://test.odoo.com',
            'ODOO_USER': 'test@example.com',
            'ODOO_PASSWORD': '',
        }).start()
        self.addCleanup(patch.stopall)

        import importlib
        importlib.reload(config)

        with self.assertRaises(SystemExit) as ctx:
            config.load_config()
        self.assertEqual(ctx.exception.code, 1)

    def test_load_config_empty_env_var(self) -> None:
        """load_config should exit when an env var is empty."""
        patch.dict(os.environ, {
            'ODOO_DB': '',
            'ODOO_URL': 'https://test.odoo.com',
            'ODOO_USER': 'test@example.com',
            'ODOO_PASSWORD': 'secret123',
        }).start()
        self.addCleanup(patch.stopall)

        import importlib
        importlib.reload(config)

        with self.assertRaises(SystemExit) as ctx:
            config.load_config()
        self.assertEqual(ctx.exception.code, 1)


class TestOdooSession(unittest.TestCase):
    """Test OdooSession class."""

    def setUp(self) -> None:
        """Set up a test session."""
        self.config: session.Config = {
            'db': 'test-db',
            'url': 'https://test.odoo.com',
            'user': 'test@example.com',
            'password': 'secret123',
        }
        self.session = session.OdooSession(self.config)

    def test_session_host_parsing(self) -> None:
        """Session should correctly parse the host from URL."""
        self.assertEqual(self.session.host, 'test.odoo.com')
        self.assertEqual(self.session.port, 443)
        self.assertEqual(self.session.scheme, 'https')

    def test_session_host_parsing_http(self) -> None:
        """Session should handle http URLs."""
        cfg = dict(self.config, url='http://localhost:8069')
        sess = session.OdooSession(cfg)
        self.assertEqual(sess.host, 'localhost')
        self.assertEqual(sess.port, 8069)
        self.assertEqual(sess.scheme, 'http')

    def test_session_base_path(self) -> None:
        """Session should preserve base path."""
        cfg = dict(self.config, url='https://test.odoo.com/odoo')
        sess = session.OdooSession(cfg)
        self.assertEqual(sess.base_path, '/odoo')

    def test_is_expired_no_cookie(self) -> None:
        """Session should be expired when no cookie exists."""
        self.assertTrue(self.session._is_expired())

    def test_is_expired_not_expired(self) -> None:
        """Session should not be expired shortly after login."""
        self.session._cookie = 'session_id=test'
        self.session._last_login = time.monotonic()
        self.assertFalse(self.session._is_expired())

    def test_is_expired_after_timeout(self) -> None:
        """Session should be expired after timeout."""
        self.session._cookie = 'session_id=test'
        self.session._last_login = time.monotonic() - 99999
        self.assertTrue(self.session._is_expired())

    def test_session_expired_error_is_runtime_error(self) -> None:
        """SessionExpiredError should be a subclass of RuntimeError."""
        self.assertTrue(issubclass(session.SessionExpiredError, RuntimeError))


class TestLogFunction(unittest.TestCase):
    """Test the _log function."""

    def setUp(self) -> None:
        """Set up test fixtures."""
        self._capture = _LogCapture()
        config.logger.addHandler(self._capture)

    def tearDown(self) -> None:
        """Tear down test fixtures."""
        config.logger.removeHandler(self._capture)
        self._capture.records.clear()

    def test_log_format(self) -> None:
        """Log message should have correct format."""
        _log('GET', '/task/data?id=1', 200)
        self.assertEqual(len(self._capture.records), 1)
        self.assertIn('GET', self._capture.records[0].getMessage())
        self.assertIn('/task/data', self._capture.records[0].getMessage())
        self.assertIn('200', self._capture.records[0].getMessage())

    def test_log_includes_client_ip(self) -> None:
        """Log message should include client IP when provided."""
        _log('GET', '/task/data?id=1', 200, '192.168.1.1')
        msg = self._capture.records[0].getMessage()
        self.assertIn('192.168.1.1', msg)
        self.assertIn('from', msg)

    def test_log_excludes_empty_client_ip(self) -> None:
        """Log message should not include 'from' when client IP is empty."""
        _log('GET', '/task/data?id=1', 200, '')
        msg = self._capture.records[0].getMessage()
        self.assertNotIn('from', msg)

    def test_log_includes_timestamp(self) -> None:
        """Log message should include ISO 8601 timestamp."""
        _log('GET', '/task/data?id=1', 200)
        self.assertRegex(
            self._capture.records[0].asctime,
            r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z',
        )


class TestGracefulShutdown(unittest.TestCase):
    """Test graceful shutdown signal handling."""

    def test_shutdown_handler_exists(self) -> None:
        """Server should define _shutdown function for signal handling."""
        self.assertTrue(hasattr(_shutdown, '__call__'))

    def test_shutdown_handler_calls_server_shutdown(self) -> None:
        """_shutdown dispatches server.shutdown() to a thread — calling it
        on the signal handler's own thread would deadlock serve_forever."""
        import time
        mock_server = MagicMock()
        _shutdown(mock_server, 0, None)
        for _ in range(100):
            if mock_server.shutdown.called:
                break
            time.sleep(0.02)
        mock_server.shutdown.assert_called_once()


class TestHandlerMethods(unittest.TestCase):
    """Test that the handler has all required HTTP method handlers."""

    def test_handler_is_http_base(self) -> None:
        """ProxyHandler should extend BaseHTTPRequestHandler."""
        from http.server import BaseHTTPRequestHandler
        self.assertTrue(issubclass(ProxyHandler, BaseHTTPRequestHandler))

    def test_get_method_exists(self) -> None:
        """do_GET should exist."""
        self.assertTrue(hasattr(ProxyHandler, 'do_GET'))

    def test_post_method_exists(self) -> None:
        """do_POST should exist."""
        self.assertTrue(hasattr(ProxyHandler, 'do_POST'))

    def test_patch_method_exists(self) -> None:
        """do_PATCH should exist."""
        self.assertTrue(hasattr(ProxyHandler, 'do_PATCH'))

    def test_put_method_exists(self) -> None:
        """do_PUT should exist."""
        self.assertTrue(hasattr(ProxyHandler, 'do_PUT'))

    def test_delete_method_exists(self) -> None:
        """do_DELETE should exist."""
        self.assertTrue(hasattr(ProxyHandler, 'do_DELETE'))

    def test_log_message_method_exists(self) -> None:
        """log_message should exist."""
        self.assertTrue(hasattr(ProxyHandler, 'log_message'))

    def test_send_json_method_exists(self) -> None:
        """_send_json should exist."""
        self.assertTrue(hasattr(ProxyHandler, '_send_json'))

    def test_handle_task_message_post_exists(self) -> None:
        """_handle_task_message_post should exist."""
        self.assertTrue(hasattr(ProxyHandler, '_handle_task_message_post'))


class TestTaskMessagePostHandler(unittest.TestCase):
    """Test POST /task/message endpoint handler."""

    def _make_request(self, path: str, body: bytes = b'{}') -> ProxyHandler:
        """Create a mock handler without calling __init__ (which needs a real socket)."""
        handler: ProxyHandler = object.__new__(ProxyHandler)
        handler.path = path
        handler.requestline = f"POST {path} HTTP/1.1"
        handler.request_version = "HTTP/1.1"
        handler.client_address = ('192.168.1.1', 54321)
        mock_headers: http.client.HTTPMessage = http.client.HTTPMessage()
        mock_headers['Content-Type'] = 'application/json'
        if body:
            mock_headers['Content-Length'] = str(len(body))
        handler.headers = mock_headers
        handler.rfile = io.BytesIO(body)
        handler.wfile = MagicMock()
        return handler

    def test_post_task_message_success(self) -> None:
        """POST /task/message should post a message and return result."""
        _server._session_config = {
            'db': 'test-db',
            'url': 'https://test.odoo.com',
            'user': 'user@example.com',
            'password': 'secret',
        }
        with patch('odoo_proxy.server.get_session') as mock_get:
            mock_sess = MagicMock()
            mock_sess.post_message.return_value = {'id': 1, 'body': '<p>ok</p>'}
            mock_get.return_value = mock_sess
            handler = self._make_request(
                '/task/message?id=3807',
                b'{"body": "Hello world"}',
            )
            handler._handle_task_message_post(parse_qs('id=3807'))
            mock_sess.post_message.assert_called_once_with(
                thread_id=3807,
                body="Hello world",
                message_type="comment",
                subtype_xmlid="mail.mt_note",
            )
            response = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])
            self.assertEqual(response['message']['body'], '<p>ok</p>')

    def test_post_task_message_missing_id(self) -> None:
        """POST /task/message without id should return 400."""
        handler = self._make_request('/task/message', b'{"body": "test"}')
        handler._handle_task_message_post({})
        response = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])
        self.assertEqual(response['error'], 'missing required parameter: id')

    def test_post_task_message_invalid_id(self) -> None:
        """POST /task/message with non-numeric id should return 400."""
        handler = self._make_request('/task/message?id=abc', b'{"body": "test"}')
        handler._handle_task_message_post(parse_qs('id=abc'))
        response = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])
        self.assertEqual(response['error'], "invalid id parameter: 'abc'")

    def test_post_task_message_missing_body(self) -> None:
        """POST /task/message without body field should return 400."""
        handler = self._make_request('/task/message?id=1', b'{}')
        handler._handle_task_message_post(parse_qs('id=1'))
        response = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])
        self.assertEqual(response['error'], 'missing required field: body')

    def test_post_task_message_invalid_json(self) -> None:
        """POST /task/message with invalid JSON should return 400."""
        handler = self._make_request('/task/message?id=1', b'not json')
        handler._handle_task_message_post(parse_qs('id=1'))
        response = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])
        self.assertEqual(response['error'], 'invalid JSON body')

    def test_post_task_message_non_object_json(self) -> None:
        """Valid JSON that is not an object must 400, not crash on .get()."""
        handler = self._make_request('/task/message?id=1', b'5')
        handler._handle_task_message_post(parse_qs('id=1'))
        response = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])
        self.assertEqual(response['error'], 'body must be a JSON object')

    def test_post_task_message_non_string_fields(self) -> None:
        """Non-string body/message_type/subtype_xmlid must 400."""
        for payload, field in (
            (b'{"body": 5}', 'body'),
            (b'{"body": "ok", "message_type": 7}', 'message_type'),
            (b'{"body": "ok", "subtype_xmlid": ["x"]}', 'subtype_xmlid'),
        ):
            handler = self._make_request('/task/message?id=1', payload)
            handler._handle_task_message_post(parse_qs('id=1'))
            response = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])
            self.assertEqual(response['error'], f'{field} must be a string')

    def test_post_task_message_invalid_content_length(self) -> None:
        """A non-numeric Content-Length must 400, not crash the handler."""
        handler = self._make_request('/task/message?id=1', b'{"body": "ok"}')
        handler.headers.replace_header('Content-Length', 'not-a-number')
        handler._handle_task_message_post(parse_qs('id=1'))
        response = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])
        self.assertEqual(response['error'], 'invalid Content-Length header')

    def test_post_task_message_negative_content_length(self) -> None:
        """A negative Content-Length must 400, not read until EOF."""
        handler = self._make_request('/task/message?id=1', b'{"body": "ok"}')
        handler.headers.replace_header('Content-Length', '-5')
        handler._handle_task_message_post(parse_qs('id=1'))
        response = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])
        self.assertEqual(response['error'], 'invalid Content-Length header')

    def test_post_task_message_502_on_error(self) -> None:
        """POST /task/message should return 502 when Odoo RPC fails."""
        _server._session_config = {
            'db': 'test-db',
            'url': 'https://test.odoo.com',
            'user': 'user@example.com',
            'password': 'secret',
        }
        with patch('odoo_proxy.server.get_session') as mock_get:
            mock_sess = MagicMock()
            mock_sess.post_message.side_effect = RuntimeError("Odoo down")
            mock_get.return_value = mock_sess
            handler = self._make_request('/task/message?id=1', b'{"body": "test"}')
            handler._handle_task_message_post(parse_qs('id=1'))
            response = json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0])
            self.assertEqual(response['error'], 'Odoo down')


class TestQueryParameterStripping(unittest.TestCase):
    """Test that query parameters are properly handled for endpoint matching."""

    def test_task_data_with_query(self) -> None:
        """Query params should not affect endpoint matching."""
        self.assertTrue(whitelist.is_allowed_endpoint('/task/data?id=3807'))

    def test_task_messages_with_query(self) -> None:
        """Query params should not affect endpoint matching."""
        self.assertTrue(whitelist.is_allowed_endpoint('/task/messages?id=3807&limit=10'))

    def test_empty_query_param(self) -> None:
        """Empty query string should still match."""
        self.assertTrue(whitelist.is_allowed_endpoint('/task/data?'))


class TestSessionLogin(unittest.TestCase):
    """Test the two-step Odoo login flow in OdooSession._login()."""

    def setUp(self) -> None:
        """Set up a session with a patched HTTPSConnection."""
        self.config: session.Config = {
            'db': 'test-db',
            'url': 'https://test.odoo.com',
            'user': 'test@example.com',
            'password': 'secret123',
        }
        self.sess = session.OdooSession(self.config)
        self._patcher = patch('odoo_proxy.session.http.client.HTTPSConnection')
        self.mock_conn_cls = self._patcher.start()

    def tearDown(self) -> None:
        """Stop the connection patch."""
        self._patcher.stop()

    @staticmethod
    def _resp(status: int, body: bytes = b'', cookie: str | None = None) -> MagicMock:
        """Build a fake HTTPResponse."""
        resp = MagicMock()
        resp.status = status
        resp.read.return_value = body
        resp.getheader.return_value = cookie
        resp.msg.get_all.return_value = [cookie] if cookie else None
        return resp

    def _conn(self, resp: MagicMock) -> MagicMock:
        """Build a fake connection returning the given response."""
        conn = MagicMock()
        conn.getresponse.return_value = resp
        return conn

    def _two_step(self, step1: MagicMock, step2: MagicMock) -> tuple[MagicMock, MagicMock]:
        """Queue two connections for the two login steps."""
        c1, c2 = self._conn(step1), self._conn(step2)
        self.mock_conn_cls.side_effect = [c1, c2]
        return c1, c2

    def test_login_success(self) -> None:
        """Successful login should store the session cookie and timestamp."""
        step1 = self._resp(
            200, b'<input name="csrf_token" value="TOK123">', 'session_id=init; Path=/'
        )
        step2 = self._resp(303, b'', 'session_id=final; Path=/; HttpOnly')
        _, c2 = self._two_step(step1, step2)
        self.sess._login()
        self.assertEqual(self.sess._cookie, 'session_id=final')
        self.assertGreater(self.sess._last_login, 0)
        args, kwargs = c2.request.call_args
        self.assertEqual(args[1], '/web/login')
        self.assertIn('csrf_token=TOK123', kwargs['body'])
        self.assertIn('login=test%40example.com', kwargs['body'])
        self.assertIn('password=secret123', kwargs['body'])

    def test_login_body_is_url_encoded(self) -> None:
        """Special characters in credentials must not corrupt the form body."""
        self.sess.config['password'] = 'p&ss=w+x=1'
        step1 = self._resp(
            200, b'<input name="csrf_token" value="TOK123">', 'session_id=init; Path=/'
        )
        step2 = self._resp(303, b'', 'session_id=final; Path=/; HttpOnly')
        _, c2 = self._two_step(step1, step2)
        self.sess._login()
        body = c2.request.call_args[1]['body']
        # Exactly three form fields — the encoded password stays one field.
        self.assertEqual(body.count('&'), 2)
        self.assertIn('password=p%26ss%3Dw%2Bx%3D1', body)

    def test_login_step1_sends_initial_cookie(self) -> None:
        """Step 2 should replay the session cookie received in step 1."""
        step1 = self._resp(
            200, b'name="csrf_token" value="T"', 'session_id=init; Path=/'
        )
        step2 = self._resp(303, b'', 'session_id=final; Path=/')
        _, c2 = self._two_step(step1, step2)
        self.sess._login()
        _, kwargs = c2.request.call_args
        self.assertEqual(kwargs['headers']['Cookie'], 'session_id=init')

    def test_login_step1_gets_login_page(self) -> None:
        """Step 1 should GET the login page (with base path)."""
        step1 = self._resp(200, b'name="csrf_token" value="T"', None)
        step2 = self._resp(200, b'', 'session_id=c; Path=/')
        c1, _ = self._two_step(step1, step2)
        self.sess._login()
        self.assertEqual(c1.request.call_args[0], ('GET', '/web/login'))

    def test_login_alt_csrf_pattern(self) -> None:
        """CSRF token should also be found in the json-style pattern."""
        step1 = self._resp(200, b'csrf_token: "ALT456"', None)
        step2 = self._resp(303, b'', 'session_id=final; Path=/')
        _, c2 = self._two_step(step1, step2)
        self.sess._login()
        _, kwargs = c2.request.call_args
        self.assertIn('csrf_token=ALT456', kwargs['body'])

    def test_login_step1_failure(self) -> None:
        """A non-200/302 step 1 should raise with the HTTP status."""
        step1 = self._resp(500)
        step2 = self._resp(303, b'', 'session_id=x')
        self._two_step(step1, step2)
        with self.assertRaisesRegex(RuntimeError, 'Login step 1 failed: HTTP 500'):
            self.sess._login()

    def test_login_no_csrf_token(self) -> None:
        """A login page without a CSRF token should raise."""
        step1 = self._resp(200, b'<html>no token here</html>', None)
        step2 = self._resp(303, b'', 'session_id=x')
        self._two_step(step1, step2)
        with self.assertRaisesRegex(RuntimeError, 'Could not extract CSRF token'):
            self.sess._login()

    def test_login_step2_failure(self) -> None:
        """A rejected credentials POST should raise with the HTTP status."""
        step1 = self._resp(200, b'name="csrf_token" value="T"', None)
        step2 = self._resp(400)
        self._two_step(step1, step2)
        with self.assertRaisesRegex(RuntimeError, 'Login step 2 failed: HTTP 400'):
            self.sess._login()

    def test_login_no_session_cookie(self) -> None:
        """A successful login POST without a session cookie should raise."""
        step1 = self._resp(200, b'name="csrf_token" value="T"', None)
        step2 = self._resp(200, b'', None)
        self._two_step(step1, step2)
        with self.assertRaisesRegex(RuntimeError, 'No session cookie received'):
            self.sess._login()

    def test_extract_session_cookie_none(self) -> None:
        """No Set-Cookie header should yield an empty cookie string."""
        resp = self._resp(200, b'', None)
        self.assertEqual(session._extract_session_cookie(resp), '')

    def test_extract_session_cookie_filters_session_id_only(self) -> None:
        """Only session_id parts of Set-Cookie should be kept."""
        resp = self._resp(200, b'', 'session_id=abc; other=1; Path=/')
        self.assertEqual(session._extract_session_cookie(resp), 'session_id=abc')

    def test_extract_session_cookie_scans_all_headers(self) -> None:
        """session_id arriving in a later repeated Set-Cookie header must be found."""
        resp = MagicMock()
        resp.status = 200
        resp.msg.get_all.return_value = [
            'other_cookie=1; Path=/',
            'session_id=late; Path=/; HttpOnly',
        ]
        self.assertEqual(session._extract_session_cookie(resp), 'session_id=late')


class TestSessionLifecycle(unittest.TestCase):
    """Test _ensure_session / _reauthenticate / _connection."""

    def setUp(self) -> None:
        """Set up a test session."""
        self.config: session.Config = {
            'db': 'test-db',
            'url': 'https://test.odoo.com',
            'user': 'u',
            'password': 'p',
        }
        self.sess = session.OdooSession(self.config)

    def test_ensure_session_logs_in_when_expired(self) -> None:
        """_ensure_session should trigger a login when there is no cookie."""
        with patch.object(self.sess, '_login') as mock_login:
            self.sess._ensure_session()
            mock_login.assert_called_once()

    def test_ensure_session_noop_when_fresh(self) -> None:
        """_ensure_session should not re-login for a fresh session."""
        self.sess._cookie = 'session_id=x'
        self.sess._last_login = time.monotonic()
        with patch.object(self.sess, '_login') as mock_login:
            self.sess._ensure_session()
            mock_login.assert_not_called()

    def test_reauthenticate_clears_cookie_and_logs_in(self) -> None:
        """_reauthenticate should drop the old cookie before logging in."""
        self.sess._cookie = 'session_id=old'
        login_order: list[str | None] = []
        with patch.object(self.sess, '_login', side_effect=lambda: login_order.append(self.sess._cookie)):
            self.sess._reauthenticate()
        self.assertEqual(login_order, [None])

    def test_connection_https(self) -> None:
        """https URLs should use HTTPSConnection with host/port/timeout."""
        with patch('odoo_proxy.session.http.client.HTTPSConnection') as https_cls, \
             patch('odoo_proxy.session.http.client.HTTPConnection') as http_cls:
            self.sess._connection()
            https_cls.assert_called_once_with('test.odoo.com', 443, timeout=30)
            http_cls.assert_not_called()

    def test_connection_http(self) -> None:
        """http URLs should use plain HTTPConnection."""
        sess = session.OdooSession(dict(self.config, url='http://localhost:8069'))
        with patch('odoo_proxy.session.http.client.HTTPSConnection') as https_cls, \
             patch('odoo_proxy.session.http.client.HTTPConnection') as http_cls:
            sess._connection()
            http_cls.assert_called_once_with('localhost', 8069, timeout=30)
            https_cls.assert_not_called()


class TestCallOdoo(unittest.TestCase):
    """Test the low-level _call_odoo response handling."""

    def setUp(self) -> None:
        """Set up a session with a patched connection factory."""
        self.config: session.Config = {
            'db': 'test-db', 'url': 'https://test.odoo.com', 'user': 'u', 'password': 'p',
        }
        self.sess = session.OdooSession(self.config)
        self.sess._cookie = 'session_id=x'
        self._patcher = patch('odoo_proxy.session.http.client.HTTPSConnection')
        self.mock_conn_cls = self._patcher.start()
        self.conn = MagicMock()
        self.mock_conn_cls.return_value = self.conn

    def tearDown(self) -> None:
        """Stop the connection patch."""
        self._patcher.stop()

    def _respond(self, status: int, data: bytes) -> None:
        resp = MagicMock()
        resp.status = status
        resp.read.return_value = data
        self.conn.getresponse.return_value = resp

    def _call(self) -> dict:
        return self.sess._call_odoo('/web/dataset/call_kw', b'{}', {})

    def test_success_returns_result(self) -> None:
        """A JSON-RPC envelope should unwrap to its result."""
        self._respond(200, b'{"result": {"x": 1}}')
        self.assertEqual(self._call(), {'x': 1})

    def test_403_raises_session_expired(self) -> None:
        """403 should signal session expiry for the retry logic."""
        self._respond(403, b'')
        with self.assertRaises(session.SessionExpiredError):
            self._call()

    def test_302_raises_session_expired(self) -> None:
        """A redirect (re-login page) should signal session expiry."""
        self._respond(302, b'')
        with self.assertRaises(session.SessionExpiredError):
            self._call()

    def test_empty_response_raises(self) -> None:
        """An empty body should raise with status and path context."""
        self._respond(200, b'')
        with self.assertRaisesRegex(RuntimeError, 'Empty response'):
            self._call()

    def test_non_json_response_raises(self) -> None:
        """Non-JSON bodies should raise with a snippet of the body."""
        self._respond(200, b'<html>oops</html>')
        with self.assertRaisesRegex(RuntimeError, 'Non-JSON response'):
            self._call()

    def test_rpc_error_key_raises(self) -> None:
        """A JSON-RPC error envelope should raise with the error detail."""
        self._respond(200, b'{"error": {"message": "boom"}}')
        with self.assertRaisesRegex(RuntimeError, 'Odoo RPC error'):
            self._call()


class TestRpcWrappers(unittest.TestCase):
    """Test call_rpc / get_messages / post_message payloads and retry logic."""

    def setUp(self) -> None:
        """Set up a session with session management stubbed out."""
        self.config: session.Config = {
            'db': 'test-db', 'url': 'https://test.odoo.com', 'user': 'u', 'password': 'p',
        }
        self.sess = session.OdooSession(self.config)
        self._ensure = patch.object(self.sess, '_ensure_session').start()
        self._reauth = patch.object(self.sess, '_reauthenticate').start()
        self._call = patch.object(self.sess, '_call_odoo').start()
        self.addCleanup(patch.stopall)

    def test_call_rpc_payload_and_path(self) -> None:
        """call_rpc should POST a jsonrpc envelope to /web/dataset/call_kw."""
        self._call.return_value = {'ok': True}
        result = self.sess.call_rpc('project.task', 'web_read', args=[[1]], kwargs={'k': 2})
        self.assertEqual(result, {'ok': True})
        path, body, headers = self._call.call_args[0]
        self.assertEqual(path, '/web/dataset/call_kw')
        self.assertEqual(headers['Content-Type'], 'application/json')
        payload = json.loads(body)
        self.assertEqual(payload['jsonrpc'], '2.0')
        self.assertEqual(payload['params']['model'], 'project.task')
        self.assertEqual(payload['params']['method'], 'web_read')
        self.assertEqual(payload['params']['args'], [[1]])
        self.assertEqual(payload['params']['kwargs'], {'k': 2})

    def test_call_rpc_retries_after_reauth(self) -> None:
        """A session-expired first attempt should re-auth and retry exactly once."""
        self._call.side_effect = [session.SessionExpiredError('403'), {'ok': True}]
        result = self.sess.call_rpc('project.task', 'web_read', args=[[1]])
        self.assertEqual(result, {'ok': True})
        self._reauth.assert_called_once()
        self.assertEqual(self._call.call_count, 2)

    def test_call_rpc_does_not_retry_twice(self) -> None:
        """A second session-expired error should propagate, not loop."""
        self._call.side_effect = session.SessionExpiredError('403')
        with self.assertRaises(session.SessionExpiredError):
            self.sess.call_rpc('project.task', 'web_read')
        self.assertEqual(self._call.call_count, 2)

    def test_get_messages_payload_and_path(self) -> None:
        """get_messages should POST thread params to /mail/thread/messages."""
        self._call.return_value = {'messages': []}
        self.sess.get_messages(3807, limit=5)
        path, body, _ = self._call.call_args[0]
        self.assertEqual(path, '/mail/thread/messages')
        payload = json.loads(body)
        self.assertEqual(payload['params']['thread_id'], 3807)
        self.assertEqual(payload['params']['thread_model'], 'project.task')
        self.assertEqual(payload['params']['limit'], 5)

    def test_get_messages_retries_after_reauth(self) -> None:
        """get_messages should also survive a session refresh."""
        self._call.side_effect = [session.SessionExpiredError('302'), {'messages': [1]}]
        self.assertEqual(self.sess.get_messages(1), {'messages': [1]})
        self._reauth.assert_called_once()

    def test_post_message_payload(self) -> None:
        """post_message posts via /mail/message/post (review 2.2 — the old
        call_kw + message_post shape passed the thread id into body's
        positional slot and could not work on a real instance)."""
        self._call.return_value = {'id': 9}
        self.sess.post_message(3807, '<p>hi</p>')
        path, body, _ = self._call.call_args[0]
        self.assertEqual(path, '/mail/message/post')
        payload = json.loads(body)
        self.assertEqual(payload['params']['thread_id'], 3807)
        self.assertEqual(payload['params']['thread_model'], 'project.task')
        self.assertEqual(payload['params']['post_data']['body'], '<p>hi</p>')
        self.assertEqual(payload['params']['post_data']['message_type'], 'comment')
        self.assertEqual(payload['params']['post_data']['subtype_xmlid'], 'mail.mt_note')

    def test_post_message_retries_after_reauth(self) -> None:
        """post_message should also survive a session refresh."""
        self._call.side_effect = [session.SessionExpiredError('403'), {'id': 9}]
        self.assertEqual(self.sess.post_message(1, 'x'), {'id': 9})
        self._reauth.assert_called_once()


class TestGetSessionSingleton(unittest.TestCase):
    """Test the global session singleton."""

    def setUp(self) -> None:
        """Reset the module-level singleton."""
        session._session = None
        session._session_config = None

    def tearDown(self) -> None:
        """Reset the module-level singleton."""
        session._session = None
        session._session_config = None

    def test_same_config_returns_same_session(self) -> None:
        """Repeated calls with the same config object reuse the session."""
        cfg: session.Config = {
            'db': 'd', 'url': 'https://x.odoo.com', 'user': 'u', 'password': 'p',
        }
        s1 = session.get_session(cfg)
        self.assertIs(session.get_session(cfg), s1)

    def test_new_config_creates_new_session(self) -> None:
        """A different config object should build a fresh session."""
        cfg1: session.Config = {
            'db': 'd', 'url': 'https://x.odoo.com', 'user': 'u', 'password': 'p',
        }
        cfg2: session.Config = {
            'db': 'd2', 'url': 'https://y.odoo.com', 'user': 'u', 'password': 'p',
        }
        s1 = session.get_session(cfg1)
        self.assertIsNot(session.get_session(cfg2), s1)

    def test_equal_dict_config_reuses_session(self) -> None:
        """An equal-but-distinct dict (rebuilt per request) must NOT re-login.

        Regression: the singleton compared by identity, so server.py's
        per-request dict literal recreated the session — and re-ran the
        two-step login — on every call.
        """
        cfg1: session.Config = {
            'db': 'd', 'url': 'https://x.odoo.com', 'user': 'u', 'password': 'p',
        }
        cfg2: session.Config = {
            'db': 'd', 'url': 'https://x.odoo.com', 'user': 'u', 'password': 'p',
        }
        self.assertIsNot(cfg1, cfg2)
        s1 = session.get_session(cfg1)
        self.assertIs(session.get_session(cfg2), s1)


class TestTaskDataHandler(unittest.TestCase):
    """Test GET /task/data handler logic."""

    def setUp(self) -> None:
        """Point the module-level config at a fake Odoo."""
        self._orig = _server._session_config
        _server._session_config = {
            'db': 'test-db', 'url': 'https://test.odoo.com',
            'user': 'u', 'password': 'p',
        }

    def tearDown(self) -> None:
        """Restore module-level config."""
        _server._session_config = self._orig

    @staticmethod
    def _make_handler(path: str, body: bytes = b'{}') -> ProxyHandler:
        """Create a handler without a real socket."""
        handler: ProxyHandler = object.__new__(ProxyHandler)
        handler.path = path
        handler.requestline = f'GET {path} HTTP/1.1'
        handler.request_version = 'HTTP/1.1'
        handler.client_address = ('192.168.1.1', 54321)
        headers: http.client.HTTPMessage = http.client.HTTPMessage()
        headers['Content-Length'] = str(len(body))
        handler.headers = headers
        handler.rfile = io.BytesIO(body)
        handler.wfile = MagicMock()
        return handler

    @staticmethod
    def _response(handler: ProxyHandler) -> dict:
        """Parse the JSON body written by _send_json."""
        return cast(dict, json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0]))

    def test_success_returns_first_task(self) -> None:
        """A web_read result list should be unwrapped to a single task."""
        with patch('odoo_proxy.server.get_session') as mock_get:
            mock_get.return_value.call_rpc.return_value = [{'id': 7, 'name': 'T'}]
            handler = self._make_handler('/task/data?id=7')
            handler._handle_task_data(parse_qs('id=7'))
            self.assertEqual(self._response(handler), {'task': {'id': 7, 'name': 'T'}})
            kwargs = mock_get.return_value.call_rpc.call_args[1]
            self.assertEqual(kwargs['model'], 'project.task')
            self.assertEqual(kwargs['method'], 'web_read')
            self.assertEqual(kwargs['args'], [[7]])

    def test_empty_result_returns_null_task(self) -> None:
        """An empty web_read result should return task: None."""
        with patch('odoo_proxy.server.get_session') as mock_get:
            mock_get.return_value.call_rpc.return_value = []
            handler = self._make_handler('/task/data?id=999')
            handler._handle_task_data(parse_qs('id=999'))
            self.assertIsNone(self._response(handler)['task'])

    def test_missing_id_returns_400(self) -> None:
        """Missing id parameter should return 400."""
        handler = self._make_handler('/task/data')
        handler._handle_task_data({})
        self.assertEqual(self._response(handler)['error'], 'missing required parameter: id')

    def test_invalid_id_returns_400(self) -> None:
        """Non-numeric id should return 400 with the offending value."""
        handler = self._make_handler('/task/data?id=abc')
        handler._handle_task_data(parse_qs('id=abc'))
        self.assertEqual(self._response(handler)['error'], "invalid id parameter: 'abc'")

    def test_rpc_failure_returns_502(self) -> None:
        """A backend RuntimeError should surface as 502 with the message."""
        with patch('odoo_proxy.server.get_session') as mock_get:
            mock_get.return_value.call_rpc.side_effect = RuntimeError('Odoo down')
            handler = self._make_handler('/task/data?id=1')
            handler._handle_task_data(parse_qs('id=1'))
            self.assertEqual(self._response(handler)['error'], 'Odoo down')


class TestTaskMessagesHandler(unittest.TestCase):
    """Test GET /task/messages handler logic."""

    def setUp(self) -> None:
        """Point the module-level config at a fake Odoo."""
        self._orig = _server._session_config
        _server._session_config = {
            'db': 'test-db', 'url': 'https://test.odoo.com',
            'user': 'u', 'password': 'p',
        }

    def tearDown(self) -> None:
        """Restore module-level config."""
        _server._session_config = self._orig

    @staticmethod
    def _make_handler(path: str) -> ProxyHandler:
        handler: ProxyHandler = object.__new__(ProxyHandler)
        handler.path = path
        handler.requestline = f'GET {path} HTTP/1.1'
        handler.request_version = 'HTTP/1.1'
        handler.client_address = ('192.168.1.1', 54321)
        headers: http.client.HTTPMessage = http.client.HTTPMessage()
        handler.headers = headers
        handler.rfile = io.BytesIO(b'')
        handler.wfile = MagicMock()
        return handler

    @staticmethod
    def _response(handler: ProxyHandler) -> dict:
        return cast(dict, json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0]))

    def test_success_returns_messages(self) -> None:
        """The messages list should be relayed unchanged."""
        with patch('odoo_proxy.server.get_session') as mock_get:
            mock_get.return_value.get_messages.return_value = {'messages': [{'id': 3}]}
            handler = self._make_handler('/task/messages?id=3')
            handler._handle_task_messages(parse_qs('id=3'))
            self.assertEqual(self._response(handler), {'messages': [{'id': 3}]})
            mock_get.return_value.get_messages.assert_called_once_with(thread_id=3)

    def test_missing_messages_key_yields_empty_list(self) -> None:
        """A result without 'messages' should normalize to an empty list."""
        with patch('odoo_proxy.server.get_session') as mock_get:
            mock_get.return_value.get_messages.return_value = {}
            handler = self._make_handler('/task/messages?id=3')
            handler._handle_task_messages(parse_qs('id=3'))
            self.assertEqual(self._response(handler), {'messages': []})

    def test_missing_id_returns_400(self) -> None:
        """Missing id parameter should return 400."""
        handler = self._make_handler('/task/messages')
        handler._handle_task_messages({})
        self.assertEqual(self._response(handler)['error'], 'missing required parameter: id')

    def test_invalid_id_returns_400(self) -> None:
        """Non-numeric id should return 400."""
        handler = self._make_handler('/task/messages?id=x')
        handler._handle_task_messages(parse_qs('id=x'))
        self.assertEqual(self._response(handler)['error'], "invalid id parameter: 'x'")

    def test_rpc_failure_returns_502(self) -> None:
        """Backend failures should surface as 502."""
        with patch('odoo_proxy.server.get_session') as mock_get:
            mock_get.return_value.get_messages.side_effect = RuntimeError('Odoo down')
            handler = self._make_handler('/task/messages?id=1')
            handler._handle_task_messages(parse_qs('id=1'))
            self.assertEqual(self._response(handler)['error'], 'Odoo down')


class TestProxyRouting(unittest.TestCase):
    """Test _proxy() routing, whitelist rejection, and method handling."""

    @staticmethod
    def _make_handler(method: str, path: str) -> ProxyHandler:
        handler: ProxyHandler = object.__new__(ProxyHandler)
        handler.path = path
        handler.command = method
        handler.requestline = f'{method} {path} HTTP/1.1'
        handler.request_version = 'HTTP/1.1'
        handler.client_address = ('192.168.1.1', 54321)
        headers: http.client.HTTPMessage = http.client.HTTPMessage()
        handler.headers = headers
        handler.rfile = io.BytesIO(b'')
        handler.wfile = MagicMock()
        return handler

    @staticmethod
    def _response(handler: ProxyHandler) -> dict:
        return cast(dict, json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0]))

    def _routed(self, method: str, path: str) -> tuple[ProxyHandler, list[str]]:
        """Run _proxy with all sub-handlers stubbed; return handler and call log."""
        handler = self._make_handler(method, path)
        calls: list[str] = []
        handler._handle_task_data = lambda p: calls.append('data')  # type: ignore[method-assign]
        handler._handle_task_messages = lambda p: calls.append('messages')  # type: ignore[method-assign]
        handler._handle_task_message_post = lambda p: calls.append('message_post')  # type: ignore[method-assign]
        handler._proxy(method)
        return handler, calls

    def test_blocked_path_returns_404(self) -> None:
        """Non-whitelisted paths should get a JSON 404, never touch Odoo."""
        handler, calls = self._routed('GET', '/web/dataset/call_kw')
        self.assertEqual(self._response(handler)['error'], 'endpoint not found')
        self.assertEqual(calls, [])

    def test_get_task_data_routes(self) -> None:
        """GET /task/data should route to the task-data handler."""
        _, calls = self._routed('GET', '/task/data?id=1')
        self.assertEqual(calls, ['data'])

    def test_get_task_messages_routes(self) -> None:
        """GET /task/messages should route to the messages handler."""
        _, calls = self._routed('GET', '/task/messages?id=1')
        self.assertEqual(calls, ['messages'])

    def test_post_task_message_routes(self) -> None:
        """POST /task/message should route to the message-post handler."""
        _, calls = self._routed('POST', '/task/message?id=1')
        self.assertEqual(calls, ['message_post'])

    def test_get_on_post_only_endpoint_returns_404(self) -> None:
        """GET /task/message (POST-only path) should return not found."""
        handler, calls = self._routed('GET', '/task/message')
        self.assertEqual(self._response(handler)['error'], 'not found')
        self.assertEqual(calls, [])

    def test_post_on_get_only_endpoint_returns_404(self) -> None:
        """POST /task/data (GET-only path) should return not found."""
        handler, calls = self._routed('POST', '/task/data')
        self.assertEqual(self._response(handler)['error'], 'not found')
        self.assertEqual(calls, [])

    def test_unsupported_method_returns_405(self) -> None:
        """PATCH/PUT/DELETE on an allowed path should return 405."""
        for method in ('PATCH', 'PUT', 'DELETE'):
            handler = self._make_handler(method, '/task/data')
            handler._proxy(method)
            self.assertEqual(self._response(handler)['error'], 'method not allowed', method)

    def test_head_returns_405_not_501(self) -> None:
        """HEAD must enter _proxy (405 + flat body), never BaseHTTP's 501."""
        self.assertTrue(hasattr(ProxyHandler, 'do_HEAD'))
        handler = self._make_handler('HEAD', '/task/data')
        handler._proxy('HEAD')
        self.assertEqual(self._response(handler)['error'], 'method not allowed')

    def test_query_params_parsed_for_handlers(self) -> None:
        """The query string should be parsed and passed to the sub-handler."""
        handler = self._make_handler('GET', '/task/data?id=42&x=1')
        seen: dict = {}
        handler._handle_task_data = lambda p: seen.update(p)  # type: ignore[method-assign]
        handler._proxy('GET')
        self.assertEqual(seen.get('id'), ['42'])

    def test_http_methods_delegate_to_proxy(self) -> None:
        """do_GET/HEAD/POST/PATCH/PUT/DELETE should each call _proxy with their method."""
        handler = self._make_handler('GET', '/task/data')
        calls: list[str] = []
        handler._proxy = calls.append  # type: ignore[method-assign]
        handler.do_GET()
        handler.do_HEAD()
        handler.do_POST()
        handler.do_PATCH()
        handler.do_PUT()
        handler.do_DELETE()
        self.assertEqual(calls, ['GET', 'HEAD', 'POST', 'PATCH', 'PUT', 'DELETE'])


class TestUpstreamDecodeRobustness(unittest.TestCase):
    """6.4 — a non-UTF-8 upstream body must surface as 502, never a crash."""

    def setUp(self) -> None:
        self.config: session.Config = {
            'db': 'test-db',
            'url': 'https://test.odoo.com',
            'user': 'u',
            'password': 'p',
        }
        self.sess = session.OdooSession(self.config)
        self.sess._cookie = 'session_id=abc'
        self.sess._last_login = time.monotonic()  # keep _ensure_session a no-op
        self._patcher = patch('odoo_proxy.session.http.client.HTTPSConnection')
        self.mock_conn_cls = self._patcher.start()

    def tearDown(self) -> None:
        self._patcher.stop()

    @staticmethod
    def _resp(status: int, body: bytes) -> MagicMock:
        resp = MagicMock()
        resp.status = status
        resp.read.return_value = body
        return resp

    def _conn(self, resp: MagicMock) -> MagicMock:
        conn = MagicMock()
        conn.getresponse.return_value = resp
        return conn

    def test_non_utf8_body_raises_runtime_error_not_unicode_error(self) -> None:
        """The latin-1 body must decode with replacement and fail the JSON
        parse as RuntimeError — a UnicodeDecodeError would escape the 502 handler."""
        self.mock_conn_cls.return_value = self._conn(self._resp(200, b'caf\xe9 gateway error'))
        try:
            self.sess._call_odoo('/web/dataset/call_kw', b'{}', {})
            self.fail('expected RuntimeError')
        except RuntimeError as exc:
            self.assertNotIsInstance(exc, UnicodeDecodeError)
            self.assertIn('Non-JSON response', str(exc))

    def test_call_odoo_closes_connection_in_finally(self) -> None:
        """A transport error must still close the connection."""
        conn = MagicMock()
        conn.request.side_effect = ConnectionResetError('boom')
        self.mock_conn_cls.return_value = conn
        with self.assertRaises(ConnectionResetError):
            self.sess._call_odoo('/web/dataset/call_kw', b'{}', {})
        conn.close.assert_called_once()

    def test_login_closes_connection_in_finally(self) -> None:
        """A failing login step 1 must still close the connection."""
        conn = MagicMock()
        conn.getresponse.side_effect = ConnectionResetError('boom')
        self.mock_conn_cls.return_value = conn
        with self.assertRaises(ConnectionResetError):
            self.sess._login()
        conn.close.assert_called_once()

    @staticmethod
    def _make_handler(path: str) -> ProxyHandler:
        handler: ProxyHandler = object.__new__(ProxyHandler)
        handler.path = path
        handler.requestline = f'GET {path} HTTP/1.1'
        handler.request_version = 'HTTP/1.1'
        handler.client_address = ('192.168.1.1', 54321)
        headers: http.client.HTTPMessage = http.client.HTTPMessage()
        handler.headers = headers
        handler.rfile = io.BytesIO(b'')
        handler.wfile = MagicMock()
        return handler

    def _get_status_error_and_logs(self, handler: ProxyHandler, invoke: object) -> tuple[int, dict, list[str]]:
        status: dict = {}
        handler.send_response = lambda s: status.update(s=s)  # type: ignore[method-assign]
        capture = _LogCapture()
        _server.logger.addHandler(capture)
        try:
            assert callable(invoke)
            invoke(handler)  # type: ignore[operator]
        finally:
            _server.logger.removeHandler(capture)
        response = cast(dict, json.loads(cast(MagicMock, handler.wfile).write.call_args[0][0]))
        logs = [r.getMessage() for r in capture.records]
        return status.get('s', 0), response, logs

    def test_task_data_non_utf8_body_returns_502_with_one_log_line(self) -> None:
        """Full handler path: garbage upstream body → 502 + flat error + one log line."""
        self.mock_conn_cls.return_value = self._conn(self._resp(200, b'caf\xe9 gateway error'))
        handler = self._make_handler('/task/data?id=1')
        with patch('odoo_proxy.server.get_session', return_value=self.sess):
            status, response, logs = self._get_status_error_and_logs(
                handler, lambda h: h._handle_task_data(parse_qs('id=1')))
        self.assertEqual(status, 502)
        self.assertIn('Non-JSON response', response['error'])
        self.assertEqual(len([line for line in logs if '/task/data' in line]), 1)

    def test_task_messages_non_utf8_body_returns_502_with_one_log_line(self) -> None:
        """Same class on the messages route."""
        self.mock_conn_cls.return_value = self._conn(self._resp(200, b'caf\xe9 gateway error'))
        handler = self._make_handler('/task/messages?id=1')
        with patch('odoo_proxy.server.get_session', return_value=self.sess):
            status, response, logs = self._get_status_error_and_logs(
                handler, lambda h: h._handle_task_messages(parse_qs('id=1')))
        self.assertEqual(status, 502)
        self.assertIn('Non-JSON response', response['error'])
        self.assertEqual(len([line for line in logs if '/task/messages' in line]), 1)


if __name__ == '__main__':
    unittest.main()
