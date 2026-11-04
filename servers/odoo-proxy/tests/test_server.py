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
        """POST /mail/message_post should be rejected."""
        self.assertFalse(whitelist.is_allowed_endpoint('/mail/message_post'))

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
        """_shutdown handler should call server.shutdown()."""
        mock_server = MagicMock()
        _shutdown(mock_server, 0, None)
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


if __name__ == '__main__':
    unittest.main()
