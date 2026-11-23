#!/usr/bin/env python3
"""Tests for the LLM inference proxy server."""

from __future__ import annotations

import contextlib
import http.client
import importlib
import io
import json
import logging
import os
import unittest
from email.message import Message
from unittest.mock import MagicMock, patch

from llm_proxy import config, whitelist  # noqa: E402
from llm_proxy.server import ProxyHandler, _shutdown, _usage_suffix  # noqa: E402


class _LogCapture(logging.Handler):
    """Captures log records for testing."""

    def __init__(self) -> None:
        super().__init__()
        self.records: list[logging.LogRecord] = []

    def emit(self, record: logging.LogRecord) -> None:
        self.records.append(record)


def _resolve(path: str) -> tuple[str, whitelist.Route, str]:
    """resolve_route() for paths that must resolve — asserts non-None so tests unpack typed values."""
    resolved = whitelist.resolve_route(path)
    assert resolved is not None, f"path {path!r} did not resolve"
    return resolved


class TestRouteResolution(unittest.TestCase):
    """Test prefix-based route resolution and prefix stripping."""

    def test_openrouter_prefix_resolves(self) -> None:
        name, route, path = _resolve("/openrouter/api/v1/chat/completions")
        self.assertEqual(name, "openrouter")
        self.assertIs(route, whitelist.OPENROUTER)
        self.assertEqual(path, "/api/v1/chat/completions")

    def test_openrouter_v1_alias_rewritten(self) -> None:
        """The public '/openrouter/v1/...' prefix is rewritten to upstream '/api/v1/...'."""
        name, _, path = _resolve("/openrouter/v1/chat/completions")
        self.assertEqual(name, "openrouter")
        self.assertEqual(path, "/api/v1/chat/completions")

    def test_openrouter_double_v1_collapsed(self) -> None:
        """pi's built-in anthropic-messages dialect sends /v1/v1/messages on a /v1 base."""
        _, _, path = _resolve("/openrouter/v1/v1/messages")
        self.assertEqual(path, "/api/v1/messages")
        self.assertTrue(whitelist.is_allowed(whitelist.OPENROUTER, "POST", path))

    def test_openrouter_v1_alias_preserves_query(self) -> None:
        _, _, path = _resolve("/openrouter/v1/models?category=programming")
        self.assertEqual(path, "/api/v1/models?category=programming")

    def test_openrouter_alias_only_at_segment_start(self) -> None:
        """'/v1abc' must not be rewritten — the alias matches a whole segment."""
        _, _, path = _resolve("/openrouter/v1abc/thing")
        self.assertEqual(path, "/v1abc/thing")

    def test_mlx_has_no_alias(self) -> None:
        _, _, path = _resolve("/mlx-serve/v1/chat/completions")
        self.assertEqual(path, "/v1/chat/completions")

    def test_mlx_prefix_resolves(self) -> None:
        name, route, path = _resolve("/mlx-serve/v1/chat/completions")
        self.assertEqual(name, "mlx-serve")
        self.assertIs(route, whitelist.MLX_SERVE)
        self.assertEqual(path, "/v1/chat/completions")

    def test_query_params_preserved_on_stripped_path(self) -> None:
        _, _, path = _resolve("/mlx-serve/v1/models?limit=2")
        self.assertEqual(path, "/v1/models?limit=2")

    def test_unknown_prefix_returns_none(self) -> None:
        self.assertIsNone(whitelist.resolve_route("/anthropic/v1/messages"))
        self.assertIsNone(whitelist.resolve_route("/"))

    def test_prefix_boundary_not_fuzzy(self) -> None:
        """/openrouterx must not match the /openrouter route."""
        self.assertIsNone(whitelist.resolve_route("/openrouterx/api/v1/models"))

    def test_bare_prefix_resolves_to_slash(self) -> None:
        name, _, path = _resolve("/openrouter")
        self.assertEqual(name, "openrouter")
        self.assertEqual(path, "/")


class TestOpenRouterWhitelist(unittest.TestCase):
    """Test the openrouter route whitelist."""

    def test_chat_completions_post_allowed(self) -> None:
        self.assertTrue(whitelist.is_allowed(whitelist.OPENROUTER, "POST", "/api/v1/chat/completions"))

    def test_anthropic_messages_post_allowed(self) -> None:
        """pi's built-in openrouter provider speaks the Anthropic-Messages dialect."""
        self.assertTrue(whitelist.is_allowed(whitelist.OPENROUTER, "POST", "/api/v1/messages"))
        self.assertFalse(whitelist.is_allowed(whitelist.OPENROUTER, "GET", "/api/v1/messages"))

    def test_models_get_allowed(self) -> None:
        """OpenRouter catalog routes (spec: /models, /models/count, /models/user)."""
        self.assertTrue(whitelist.is_allowed(whitelist.OPENROUTER, "GET", "/api/v1/models"))
        # spec routes: /model/{author}/{slug} (singular) and /models/.../endpoints
        self.assertTrue(whitelist.is_allowed(whitelist.OPENROUTER, "GET", "/api/v1/model/openai/gpt-4o"))
        self.assertTrue(whitelist.is_allowed(whitelist.OPENROUTER, "GET", "/api/v1/models/openai/gpt-4o/endpoints"))
        # real flat subroutes: /models/count, /models/user
        self.assertTrue(whitelist.is_allowed(whitelist.OPENROUTER, "GET", "/api/v1/models/count"))
        self.assertTrue(whitelist.is_allowed(whitelist.OPENROUTER, "GET", "/api/v1/models/user"))
        self.assertTrue(whitelist.is_allowed(whitelist.OPENROUTER, "GET", "/api/v1/providers"))

    def test_key_and_generation_blocked(self) -> None:
        """Key identity/spend metadata stays out — readable through the injected key."""
        self.assertFalse(whitelist.is_allowed(whitelist.OPENROUTER, "GET", "/api/v1/key"))
        self.assertFalse(whitelist.is_allowed(whitelist.OPENROUTER, "GET", "/api/v1/generation"))

    def test_admin_paths_blocked(self) -> None:
        self.assertFalse(whitelist.is_allowed(whitelist.OPENROUTER, "GET", "/api/v1/admin"))
        self.assertFalse(whitelist.is_allowed(whitelist.OPENROUTER, "POST", "/api/v1/keys"))
        # no bare two-segment /models/{author}/{slug} route in the spec
        self.assertFalse(whitelist.is_allowed(whitelist.OPENROUTER, "GET", "/api/v1/models/openai/gpt-4o"))
        self.assertFalse(whitelist.is_allowed(whitelist.OPENROUTER, "GET", "/api/v1/models/a/b/c"))
        # account-management routes stay outside the whitelist
        self.assertFalse(whitelist.is_allowed(whitelist.OPENROUTER, "GET", "/api/v1/credits"))
        self.assertFalse(whitelist.is_allowed(whitelist.OPENROUTER, "GET", "/api/v1/keys/user"))
        self.assertFalse(whitelist.is_allowed(whitelist.OPENROUTER, "POST", "/api/v1/guardrails"))
        self.assertFalse(whitelist.is_allowed(whitelist.OPENROUTER, "POST", "/api/v1/batches"))

    def test_wrong_method_blocked(self) -> None:
        self.assertFalse(whitelist.is_allowed(whitelist.OPENROUTER, "GET", "/api/v1/chat/completions"))
        self.assertFalse(whitelist.is_allowed(whitelist.OPENROUTER, "POST", "/api/v1/models"))


class TestMlxServeWhitelist(unittest.TestCase):
    """Test the mlx-serve route whitelist."""

    def test_chat_completions_post_allowed(self) -> None:
        self.assertTrue(whitelist.is_allowed(whitelist.MLX_SERVE, "POST", "/v1/chat/completions"))

    def test_anthropic_messages_post_allowed(self) -> None:
        self.assertTrue(whitelist.is_allowed(whitelist.MLX_SERVE, "POST", "/v1/messages"))

    def test_health_get_allowed(self) -> None:
        self.assertTrue(whitelist.is_allowed(whitelist.MLX_SERVE, "GET", "/health"))

    def test_models_get_allowed(self) -> None:
        self.assertTrue(whitelist.is_allowed(whitelist.MLX_SERVE, "GET", "/v1/models"))

    def test_other_paths_blocked(self) -> None:
        self.assertFalse(whitelist.is_allowed(whitelist.MLX_SERVE, "GET", "/"))
        self.assertFalse(whitelist.is_allowed(whitelist.MLX_SERVE, "GET", "/admin/shutdown"))
        self.assertFalse(whitelist.is_allowed(whitelist.MLX_SERVE, "GET", "/v1/completions"))
        self.assertFalse(whitelist.is_allowed(whitelist.MLX_SERVE, "POST", "/v1/completions"))
        # no GET-one-model route in the mlx-serve API docs
        self.assertFalse(whitelist.is_allowed(whitelist.MLX_SERVE, "GET", "/v1/models/some-model"))

    def test_admin_routes_blocked(self) -> None:
        """Model lifecycle and rescan routes stay outside the whitelist."""
        self.assertFalse(whitelist.is_allowed(whitelist.MLX_SERVE, "POST", "/v1/load-model"))
        self.assertFalse(whitelist.is_allowed(whitelist.MLX_SERVE, "POST", "/v1/unload-model"))
        self.assertFalse(whitelist.is_allowed(whitelist.MLX_SERVE, "POST", "/v1/models/rescan"))
        self.assertFalse(whitelist.is_allowed(whitelist.MLX_SERVE, "GET", "/metrics"))

    def test_path_allowed_any_method_helper(self) -> None:
        self.assertTrue(whitelist.path_allowed_any_method(whitelist.MLX_SERVE, "/v1/chat/completions"))
        self.assertFalse(whitelist.path_allowed_any_method(whitelist.MLX_SERVE, "/v1/completions"))


class TestRouteEnabled(unittest.TestCase):
    """Test credential-gated route enablement."""

    def test_openrouter_requires_key(self) -> None:
        with patch.object(config, "OPENROUTER_API_KEY", ""):
            self.assertFalse(whitelist.route_enabled("openrouter"))
        with patch.object(config, "OPENROUTER_API_KEY", "sk-or-x"):
            self.assertTrue(whitelist.route_enabled("openrouter"))

    def test_mlx_always_enabled(self) -> None:
        with patch.object(config, "OPENROUTER_API_KEY", ""):
            self.assertTrue(whitelist.route_enabled("mlx-serve"))


class TestModelPolicy(unittest.TestCase):
    """Test model extraction and the ALLOWED_MODELS policy."""

    def test_extract_model_from_json(self) -> None:
        body = json.dumps({"model": "openai/gpt-4o", "messages": []}).encode()
        self.assertEqual(whitelist.extract_model(body), "openai/gpt-4o")

    def test_extract_model_non_json_returns_none(self) -> None:
        self.assertIsNone(whitelist.extract_model(b"not json"))
        self.assertIsNone(whitelist.extract_model(b""))

    def test_extract_model_missing_field_returns_none(self) -> None:
        self.assertIsNone(whitelist.extract_model(b'{"messages": []}'))

    def test_empty_allowlist_allows_everything(self) -> None:
        with patch.object(config, "ALLOWED_MODELS", frozenset()):
            self.assertTrue(whitelist.is_model_allowed("anything/at-all"))
            self.assertTrue(whitelist.is_model_allowed(None))

    def test_allowlist_enforced(self) -> None:
        allowed = frozenset({"openai/gpt-4o", "qwen/qwen3.6-35b-a3b"})
        with patch.object(config, "ALLOWED_MODELS", allowed):
            self.assertTrue(whitelist.is_model_allowed("openai/gpt-4o"))
            self.assertFalse(whitelist.is_model_allowed("anthropic/claude-opus-4"))

    def test_unknown_model_allowed_when_list_set(self) -> None:
        """A request whose body carries no model field cannot be policed."""
        with patch.object(config, "ALLOWED_MODELS", frozenset({"openai/gpt-4o"})):
            self.assertTrue(whitelist.is_model_allowed(None))


class TestConfiguration(unittest.TestCase):
    """Test configuration loading from the environment."""

    def _reload(self, env: dict[str, str]):
        with patch.dict(os.environ, env, clear=False):
            return importlib.reload(config)

    def tearDown(self) -> None:
        """Restore config from the ambient environment."""
        importlib.reload(config)

    def test_defaults(self) -> None:
        cfg = self._reload({"PROXY_PORT": "", "OPENROUTER_API_KEY": "", "LLM_PROXY_TOKEN": "",
                            "MLX_SERVE_URL": "", "LLM_UPSTREAM_TIMEOUT": "", "ALLOWED_MODELS": ""})
        self.assertEqual(cfg.PORT, 8089)
        self.assertEqual(cfg.OPENROUTER_API_KEY, "")
        self.assertEqual(cfg.LLM_PROXY_TOKEN, "")
        self.assertEqual(cfg.MLX_SERVE_URL, "http://host.docker.internal:11234")
        self.assertEqual(cfg.UPSTREAM_TIMEOUT, 600)
        self.assertEqual(cfg.ALLOWED_MODELS, frozenset())

    def test_env_overrides(self) -> None:
        cfg = self._reload({
            "PROXY_PORT": "9099",
            "OPENROUTER_API_KEY": " sk-or-secret ",
            "LLM_PROXY_TOKEN": "gate-token",
            "MLX_SERVE_URL": "http://127.0.0.1:11234/",
            "LLM_UPSTREAM_TIMEOUT": "120",
            "ALLOWED_MODELS": " openai/gpt-4o , qwen/qwen3.6 ",
        })
        self.assertEqual(cfg.PORT, 9099)
        self.assertEqual(cfg.OPENROUTER_API_KEY, "sk-or-secret")
        self.assertEqual(cfg.LLM_PROXY_TOKEN, "gate-token")
        self.assertEqual(cfg.MLX_SERVE_URL, "http://127.0.0.1:11234")
        self.assertEqual(cfg.UPSTREAM_TIMEOUT, 120)
        self.assertEqual(cfg.ALLOWED_MODELS, frozenset({"openai/gpt-4o", "qwen/qwen3.6"}))

    def test_validate_warns_without_openrouter_key(self) -> None:
        buf = io.StringIO()
        with patch.object(config, "OPENROUTER_API_KEY", ""), contextlib.redirect_stderr(buf):
            config.validate_config()  # must warn, not exit
        self.assertIn("OPENROUTER_API_KEY is not set", buf.getvalue())

    def test_log_format(self) -> None:
        """Log records are emitted through the 'llm-proxy' logger."""
        self.assertEqual(config.logger.name, "llm-proxy")
        formatter = config.logger.handlers[0].formatter
        assert formatter is not None
        self.assertEqual(formatter._fmt, "[proxy] %(asctime)s %(message)s")


class TestUsageSuffix(unittest.TestCase):
    """Test token-usage extraction for request logging."""

    def test_usage_extracted(self) -> None:
        body = json.dumps({"usage": {"prompt_tokens": 120, "completion_tokens": 34}}).encode()
        self.assertEqual(_usage_suffix(body), " tokens=120+34")

    def test_anthropic_usage_extracted(self) -> None:
        """The /messages dialect reports input_tokens/output_tokens — both
        key pairs must log instead of tokens=?+?."""
        body = json.dumps({"usage": {"input_tokens": 88, "output_tokens": 21}}).encode()
        self.assertEqual(_usage_suffix(body), " tokens=88+21")

    def test_no_usage_returns_empty(self) -> None:
        self.assertEqual(_usage_suffix(b'{"choices": []}'), "")
        self.assertEqual(_usage_suffix(b"not json"), "")
        self.assertEqual(_usage_suffix(b"[1, 2]"), "")


class TestGracefulShutdown(unittest.TestCase):
    def test_shutdown_calls_server_shutdown(self) -> None:
        """shutdown() is dispatched to a thread — on the handler's own thread
        it would deadlock against serve_forever()."""
        import time
        mock_server = MagicMock()
        _shutdown(mock_server, 15, None)
        for _ in range(100):
            if mock_server.shutdown.called:
                break
            time.sleep(0.02)
        mock_server.shutdown.assert_called_once()


class TestProxyForwarding(unittest.TestCase):
    """Test the core _proxy() logic: routing, injection, policy, streaming."""

    def setUp(self) -> None:
        """Set up fake connections for every test."""
        self.mock_https_cls = MagicMock()
        self.mock_http_cls = MagicMock()
        self.conn = MagicMock()
        self.mock_https_cls.return_value = self.conn
        self.mock_http_cls.return_value = self.conn
        self.resp = MagicMock()
        self.resp.status = 200
        self.resp.read.return_value = b'{"choices": [], "usage": {"prompt_tokens": 5, "completion_tokens": 7}}'
        self.resp.getheaders.return_value = [("Content-Type", "application/json")]
        self.resp.getheader.return_value = "application/json"
        self.conn.getresponse.return_value = self.resp
        self._p1 = patch("llm_proxy.server.http.client.HTTPSConnection", self.mock_https_cls)
        self._p2 = patch("llm_proxy.server.http.client.HTTPConnection", self.mock_http_cls)
        self._p1.start()
        self._p2.start()
        self._p3 = patch.object(config, "OPENROUTER_API_KEY", "or_key")
        self._p4 = patch.object(config, "LLM_PROXY_TOKEN", "")
        self._p5 = patch.object(config, "ALLOWED_MODELS", frozenset())
        self._p3.start()
        self._p4.start()
        self._p5.start()

    def tearDown(self) -> None:
        for p in (self._p1, self._p2, self._p3, self._p4, self._p5):
            p.stop()

    @staticmethod
    def _make_handler(
        path: str,
        headers: dict[str, str] | None = None,
        body: bytes = b"",
        method: str = "POST",
    ) -> ProxyHandler:
        """Build a ProxyHandler without running the real request handshake."""
        handler = ProxyHandler.__new__(ProxyHandler)
        handler.path = path
        handler.command = method
        handler.request_version = "HTTP/1.0"
        handler.requestline = f"{method} {path} HTTP/1.0"
        handler.client_address = ("192.168.1.100", 54321)
        msg = Message()
        for key, value in (headers or {}).items():
            msg[key] = value
        msg["Content-Length"] = str(len(body))
        handler.headers = msg
        handler.rfile = io.BytesIO(body)
        handler.wfile = io.BytesIO()
        return handler

    @staticmethod
    def _parse_response(raw: bytes) -> tuple[int, dict[str, str], bytes]:
        """Split the raw HTTP response written to wfile into status, headers, body."""
        head, _, body = raw.partition(b"\r\n\r\n")
        lines = head.split(b"\r\n")
        status = int(lines[0].split(b" ")[1])
        headers: dict[str, str] = {}
        for line in lines[1:]:
            key, _, value = line.partition(b": ")
            headers[key.decode().lower()] = value.decode()
        return status, headers, body

    @staticmethod
    def _output(handler: ProxyHandler) -> bytes:
        assert isinstance(handler.wfile, io.BytesIO)
        return handler.wfile.getvalue()

    def _forwarded(self) -> tuple[str, str, bytes | None, dict[str, str]]:
        """Return (method, path, body, headers) passed to conn.request."""
        args, kwargs = self.conn.request.call_args
        return args[0], args[1], kwargs.get("body"), kwargs.get("headers")

    # --- rejection paths ----------------------------------------------------

    def test_unknown_route_returns_404(self) -> None:
        handler = self._make_handler("/anthropic/v1/messages")
        handler._proxy("POST")
        status, _, body = self._parse_response(self._output(handler))
        self.assertEqual(status, 404)
        self.assertIn(b"not found", body)
        self.conn.request.assert_not_called()

    def test_blocked_path_returns_404(self) -> None:
        handler = self._make_handler("/openrouter/api/v1/admin")
        handler._proxy("GET")
        status, _, body = self._parse_response(self._output(handler))
        self.assertEqual(status, 404)
        self.assertIn(b"endpoint not allowed", body)
        self.conn.request.assert_not_called()

    def test_wrong_method_returns_405(self) -> None:
        handler = self._make_handler("/openrouter/api/v1/chat/completions", method="GET")
        handler._proxy("GET")
        status, _, body = self._parse_response(self._output(handler))
        self.assertEqual(status, 405)
        self.assertIn(b"endpoint not allowed", body)
        self.conn.request.assert_not_called()

    def test_head_on_whitelisted_path_returns_405(self) -> None:
        """HEAD must enter _proxy (405 + flat body), never BaseHTTP's 501."""
        self.assertTrue(hasattr(ProxyHandler, "do_HEAD"))
        handler = self._make_handler("/openrouter/api/v1/chat/completions", method="HEAD")
        handler._proxy("HEAD")
        status, _, body = self._parse_response(self._output(handler))
        self.assertEqual(status, 405)
        self.assertIn(b"endpoint not allowed", body)
        self.conn.request.assert_not_called()

    def test_head_on_unknown_prefix_returns_404(self) -> None:
        handler = self._make_handler("/nope/v1/models", method="HEAD")
        handler._proxy("HEAD")
        status, _, body = self._parse_response(self._output(handler))
        self.assertEqual(status, 404)
        self.assertIn(b"not found", body)

    def test_invalid_content_length_returns_400(self) -> None:
        """A non-numeric Content-Length must 400, not crash the handler."""
        handler = self._make_handler("/mlx-serve/v1/models", method="GET")
        handler.headers.replace_header("Content-Length", "not-a-number")
        handler._proxy("GET")
        status, _, body = self._parse_response(self._output(handler))
        self.assertEqual(status, 400)
        self.assertIn(b"invalid Content-Length header", body)
        self.conn.request.assert_not_called()

    def test_negative_content_length_returns_400(self) -> None:
        """A negative Content-Length must 400, not crash rfile.read or block."""
        handler = self._make_handler("/mlx-serve/v1/models", method="GET")
        handler.headers.replace_header("Content-Length", "-5")
        handler._proxy("GET")
        status, _, body = self._parse_response(self._output(handler))
        self.assertEqual(status, 400)
        self.assertIn(b"invalid Content-Length header", body)
        self.conn.request.assert_not_called()

    def test_all_http_methods_delegate_to_proxy(self) -> None:
        """do_GET/HEAD/POST/PUT/PATCH/DELETE should each call _proxy with their method."""
        handler = self._make_handler("/mlx-serve/v1/models", method="GET")
        calls: list[str] = []
        handler._proxy = calls.append  # type: ignore[method-assign]
        handler.do_GET()
        handler.do_HEAD()
        handler.do_POST()
        handler.do_PUT()
        handler.do_PATCH()
        handler.do_DELETE()
        self.assertEqual(calls, ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"])

    def test_disabled_route_returns_404(self) -> None:
        with patch.object(config, "OPENROUTER_API_KEY", ""):
            handler = self._make_handler("/openrouter/api/v1/chat/completions", body=b"{}")
            handler._proxy("POST")
        status, _, body = self._parse_response(self._output(handler))
        self.assertEqual(status, 404)
        self.assertIn(b"route not configured", body)
        self.conn.request.assert_not_called()

    # --- token gate -----------------------------------------------------------

    def test_token_gate_rejects_missing_auth(self) -> None:
        with patch.object(config, "LLM_PROXY_TOKEN", "gate"):
            handler = self._make_handler("/mlx-serve/v1/chat/completions", body=b"{}")
            handler._proxy("POST")
        status, _, body = self._parse_response(self._output(handler))
        self.assertEqual(status, 401)
        self.assertIn(b"unauthorized", body)
        self.conn.request.assert_not_called()

    def test_token_gate_accepts_correct_auth(self) -> None:
        with patch.object(config, "LLM_PROXY_TOKEN", "gate"):
            handler = self._make_handler(
                "/mlx-serve/v1/chat/completions",
                headers={"Authorization": "Bearer gate"},
                body=b"{}",
            )
            handler._proxy("POST")
        self.assertEqual(self._parse_response(self._output(handler))[0], 200)
        self.conn.request.assert_called_once()

    # --- model policy ---------------------------------------------------------

    def test_disallowed_model_returns_403(self) -> None:
        body = json.dumps({"model": "evil/model"}).encode()
        with patch.object(config, "ALLOWED_MODELS", frozenset({"openai/gpt-4o"})):
            handler = self._make_handler("/openrouter/api/v1/chat/completions", body=body)
            handler._proxy("POST")
        status, _, out = self._parse_response(self._output(handler))
        self.assertEqual(status, 403)
        self.assertIn(b"model not allowed", out)
        self.conn.request.assert_not_called()

    def test_allowed_model_forwards(self) -> None:
        body = json.dumps({"model": "openai/gpt-4o"}).encode()
        with patch.object(config, "ALLOWED_MODELS", frozenset({"openai/gpt-4o"})):
            handler = self._make_handler("/openrouter/api/v1/chat/completions", body=body)
            handler._proxy("POST")
        self.assertEqual(self._parse_response(self._output(handler))[0], 200)
        self.conn.request.assert_called_once()

    # --- review 2.5 / 15: strict + dialect-complete model gate ----------------

    def test_missing_model_rejected_when_allowlist_set(self) -> None:
        """With ALLOWED_MODELS configured a body without a parsable model
        must not slip past the gate."""
        with patch.object(config, "ALLOWED_MODELS", frozenset({"openai/gpt-4o"})):
            handler = self._make_handler("/openrouter/api/v1/chat/completions", body=b"{}")
            handler._proxy("POST")
        status, _, out = self._parse_response(self._output(handler))
        self.assertEqual(status, 400)
        self.assertIn(b"model field required", out)
        self.conn.request.assert_not_called()

    def test_unparsable_body_rejected_when_allowlist_set(self) -> None:
        with patch.object(config, "ALLOWED_MODELS", frozenset({"openai/gpt-4o"})):
            handler = self._make_handler("/openrouter/api/v1/chat/completions", body=b"not json")
            handler._proxy("POST")
        self.assertEqual(self._parse_response(self._output(handler))[0], 400)
        self.conn.request.assert_not_called()

    def test_messages_dialect_policed_too(self) -> None:
        """/v1/messages carries the same model field — the allowlist applies."""
        body = json.dumps({"model": "evil/model"}).encode()
        with patch.object(config, "ALLOWED_MODELS", frozenset({"openai/gpt-4o"})):
            handler = self._make_handler("/mlx-serve/v1/messages", body=body)
            handler._proxy("POST")
        status, _, out = self._parse_response(self._output(handler))
        self.assertEqual(status, 403)
        self.assertIn(b"model not allowed", out)
        self.conn.request.assert_not_called()

    def test_messages_allowed_model_forwards(self) -> None:
        body = json.dumps({"model": "openai/gpt-4o"}).encode()
        with patch.object(config, "ALLOWED_MODELS", frozenset({"openai/gpt-4o"})):
            handler = self._make_handler("/openrouter/api/v1/messages", body=body)
            handler._proxy("POST")
        self.assertEqual(self._parse_response(self._output(handler))[0], 200)
        self.conn.request.assert_called_once()

    def test_no_allowlist_means_model_optional(self) -> None:
        """Without a policy there is nothing to enforce — upstream decides."""
        with patch.object(config, "ALLOWED_MODELS", frozenset()):
            handler = self._make_handler("/mlx-serve/v1/chat/completions", body=b"{}")
            handler._proxy("POST")
        self.assertEqual(self._parse_response(self._output(handler))[0], 200)

    def test_error_body_shape_is_flat_error(self) -> None:
        """Review 9 — uniform {"error": "..."} body across all four servers."""
        handler = self._make_handler("/nope/v1/chat/completions", body=b"{}")
        handler._proxy("POST")
        _, _, out = self._parse_response(self._output(handler))
        import json as _json
        self.assertEqual(_json.loads(out), {"error": "not found"})

    # --- forwarding -----------------------------------------------------------

    def test_prefix_stripped_before_forward(self) -> None:
        handler = self._make_handler("/openrouter/api/v1/chat/completions", body=b"{}")
        handler._proxy("POST")
        method, path, _, _ = self._forwarded()
        self.assertEqual(method, "POST")
        self.assertEqual(path, "/api/v1/chat/completions")

    def test_public_v1_alias_forwarded_as_upstream_path(self) -> None:
        handler = self._make_handler("/openrouter/v1/chat/completions", body=b"{}")
        handler._proxy("POST")
        _, path, _, _ = self._forwarded()
        self.assertEqual(path, "/api/v1/chat/completions")

    def test_query_preserved_on_forward(self) -> None:
        handler = self._make_handler("/mlx-serve/v1/models?limit=2", method="GET")
        handler._proxy("GET")
        _, path, _, _ = self._forwarded()
        self.assertEqual(path, "/v1/models?limit=2")

    def test_openrouter_key_injected_and_client_auth_overridden(self) -> None:
        handler = self._make_handler(
            "/openrouter/api/v1/chat/completions",
            headers={"Authorization": "Bearer client-stuff"},
            body=b"{}",
        )
        handler._proxy("POST")
        _, _, _, headers = self._forwarded()
        self.assertEqual(headers["authorization"], "Bearer or_key")

    def test_mlx_client_auth_stripped(self) -> None:
        handler = self._make_handler(
            "/mlx-serve/v1/chat/completions",
            headers={"Authorization": "Bearer none"},
            body=b"{}",
        )
        handler._proxy("POST")
        _, _, _, headers = self._forwarded()
        self.assertNotIn("authorization", headers)

    def test_hop_by_hop_headers_stripped(self) -> None:
        handler = self._make_handler(
            "/openrouter/api/v1/chat/completions",
            headers={"Connection": "keep-alive", "Transfer-Encoding": "chunked", "Host": "localhost:8089"},
            body=b"{}",
        )
        handler._proxy("POST")
        _, _, _, headers = self._forwarded()
        for hop in ("connection", "keep-alive", "transfer-encoding"):
            self.assertNotIn(hop, headers)
        self.assertEqual(headers["host"], "openrouter.ai")

    def test_https_target_used_for_openrouter(self) -> None:
        handler = self._make_handler("/openrouter/api/v1/chat/completions", body=b"{}")
        handler._proxy("POST")
        self.mock_https_cls.assert_called_once_with("openrouter.ai", 443, timeout=config.UPSTREAM_TIMEOUT)
        self.mock_http_cls.assert_not_called()

    def test_http_target_used_for_mlx(self) -> None:
        handler = self._make_handler("/mlx-serve/v1/chat/completions", body=b"{}")
        handler._proxy("POST")
        self.mock_http_cls.assert_called_once()
        self.mock_https_cls.assert_not_called()

    def test_response_body_and_status_relayed(self) -> None:
        handler = self._make_handler("/openrouter/api/v1/chat/completions", body=b"{}")
        handler._proxy("POST")
        status, headers, body = self._parse_response(self._output(handler))
        self.assertEqual(status, 200)
        self.assertEqual(headers["content-type"], "application/json")
        self.assertIn(b'"choices": []', body)

    def test_stream_relayed_unbuffered(self) -> None:
        """SSE responses are byte-copied chunk by chunk, not buffered."""
        self.resp.getheader.return_value = "text/event-stream; charset=utf-8"
        self.resp.getheaders.return_value = [("Content-Type", "text/event-stream")]
        self.resp.read.side_effect = [b"data: a\n\n", b"data: b\n\n", b""]
        handler = self._make_handler("/openrouter/api/v1/chat/completions", body=b"{}")
        handler._proxy("POST")
        status, headers, body = self._parse_response(self._output(handler))
        self.assertEqual(status, 200)
        self.assertEqual(headers["content-type"], "text/event-stream")
        self.assertIn(b"data: a\n\n", body)
        self.assertIn(b"data: b\n\n", body)
        self.assertEqual(self.resp.read.call_count, 3)

    # --- logging ----------------------------------------------------------------

    def test_request_logged_with_model_and_usage(self) -> None:
        capture = _LogCapture()
        config.logger.addHandler(capture)
        try:
            body = json.dumps({"model": "openai/gpt-4o"}).encode()
            handler = self._make_handler("/openrouter/api/v1/chat/completions", body=body)
            handler._proxy("POST")
        finally:
            config.logger.removeHandler(capture)
        lines = [r.getMessage() for r in capture.records]
        self.assertTrue(
            any("200" in line and "model=openai/gpt-4o" in line and "tokens=5+7" in line for line in lines),
            f"expected a completion log line, got: {lines}",
        )

    def test_upstream_failure_returns_502(self) -> None:
        self.conn.request.side_effect = http.client.HTTPException("boom")
        handler = self._make_handler("/openrouter/api/v1/chat/completions", body=b"{}")
        handler._proxy("POST")
        status, _, body = self._parse_response(self._output(handler))
        self.assertEqual(status, 502)
        self.assertIn(b"upstream request failed", body)

    def test_upstream_failure_logs_exactly_once(self) -> None:
        """7.2 — the 502 path must not double-log; the exception stays visible."""
        self.conn.request.side_effect = ConnectionRefusedError("connection refused")
        capture = _LogCapture()
        config.logger.addHandler(capture)
        try:
            handler = self._make_handler("/openrouter/api/v1/chat/completions", body=b"{}")
            handler._proxy("POST")
        finally:
            config.logger.removeHandler(capture)
        lines = [r.getMessage() for r in capture.records]
        self.assertEqual(len(lines), 1, f"expected one log line, got: {lines}")
        self.assertIn("502", lines[0])
        self.assertIn("connection refused", lines[0])

    def test_midstream_upstream_failure_logs_exactly_once(self) -> None:
        """7.2 — after the headers went out only the detail line remains."""
        self.resp.getheader.return_value = "text/event-stream"
        self.resp.read.side_effect = OSError("stream reset")
        capture = _LogCapture()
        config.logger.addHandler(capture)
        try:
            handler = self._make_handler("/openrouter/api/v1/chat/completions", body=b"{}")
            handler._proxy("POST")
        finally:
            config.logger.removeHandler(capture)
        lines = [r.getMessage() for r in capture.records]
        self.assertEqual(len(lines), 1, f"expected one log line, got: {lines}")
        self.assertIn("502", lines[0])
        self.assertIn("stream reset", lines[0])


if __name__ == "__main__":
    unittest.main()
