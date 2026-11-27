#!/usr/bin/env python3
"""Tests for the Thunderbird proxy server."""

from __future__ import annotations

import hashlib
import hmac
import http.client
import http.server
import importlib
import io
import json
import logging
import os
import threading
import unittest
from contextlib import redirect_stderr
from typing import Any
from unittest.mock import patch

from thunderbird_proxy import config, whitelist
from thunderbird_proxy import server as server_module
from thunderbird_proxy.bridge import Bridge, BridgeError
from thunderbird_proxy.server import ProxyHandler, _shutdown

TEST_TOKEN = "test-token"
TEST_ADDON_TOKEN = "test-addon-token"
TEST_ADDON_SECRET = "test-addon-secret"


class _LogCapture(logging.Handler):
    """Captures log records for testing."""

    def __init__(self) -> None:
        super().__init__()
        self.records: list[logging.LogRecord] = []

    def emit(self, record: logging.LogRecord) -> None:
        self.records.append(record)


# ---------------------------------------------------------------------------
# Whitelist / command mapping
# ---------------------------------------------------------------------------


class TestWhitelist(unittest.TestCase):
    def test_agent_endpoints_map_to_commands(self) -> None:
        cases = {
            "GET /accounts": "accounts.list",
            "GET /identities?account=acc1": "identities.list",
            "GET /folders?account=acc1": "folders.list",
            "GET /mail/list?folderId=f1&limit=5": "messages.list",
            "GET /mail/search?subject=hi": "messages.search",
            "GET /mail/msgABC123": "message.get",
            "POST /mail/send": "message.send",
            "POST /mail/draft": "message.draft",
            "PATCH /mail/msgABC123": "message.update",
            "DELETE /mail/msgABC123": "message.delete",
        }
        for spec, command in cases.items():
            method, path = spec.split(" ")
            matched = whitelist.match_endpoint(method, path)
            self.assertIsNotNone(matched, spec)
            assert matched is not None
            self.assertEqual(matched[0].command, command, spec)

    def test_status_is_proxy_local(self) -> None:
        matched = whitelist.match_endpoint("GET", "/status")
        assert matched is not None
        self.assertIsNone(matched[0].command)

    def test_search_query_params_forwarded(self) -> None:
        matched = whitelist.match_endpoint("GET", "/mail/search?unread=true&to=a%40b.c&subject=hi&evil=1")
        assert matched is not None
        self.assertEqual(matched[1], {"unread": "true", "to": "a@b.c", "subject": "hi"})

    def test_unknown_paths_never_match(self) -> None:
        for path in ("/", "/mail", "/mail/forward/xyz", "/admin", "/addon/poll", "/mail/list/extra"):
            self.assertIsNone(whitelist.match_endpoint("GET", path), path)

    def test_wrong_method_is_known_path(self) -> None:
        self.assertIsNone(whitelist.match_endpoint("POST", "/accounts"))
        self.assertTrue(whitelist.path_known_any_method("/accounts"))
        self.assertFalse(whitelist.path_known_any_method("/nope"))

    def test_head_mirrors_get(self) -> None:
        matched = whitelist.match_endpoint("HEAD", "/accounts")
        self.assertIsNotNone(matched)

    def test_path_param_extracted_and_unquoted(self) -> None:
        matched = whitelist.match_endpoint("GET", "/mail/abc%2Fdef%3D%3D")
        assert matched is not None
        self.assertEqual(matched[1]["message_id"], "abc/def==")

    def test_only_whitelisted_query_keys_pass(self) -> None:
        matched = whitelist.match_endpoint("GET", "/mail/list?folderId=f1&evil=1")
        assert matched is not None
        self.assertEqual(matched[1], {"folderId": "f1"})

    def test_command_set_is_closed(self) -> None:
        self.assertEqual(
            whitelist.COMMANDS,
            {
                "accounts.list", "identities.list", "folders.list", "messages.list", "messages.search",
                "message.get", "message.send", "message.draft", "message.update", "message.delete",
            },
        )

    def test_addon_face_is_exactly_the_fixed_set(self) -> None:
        self.assertEqual(
            whitelist.ADDON_ENDPOINTS,
            {
                ("POST", "/addon/hello"),
                ("GET", "/addon/poll"),
                ("POST", "/addon/result"),
                ("GET", "/addon/status"),
            },
        )


class TestBodyValidation(unittest.TestCase):
    def test_send_requires_to_subject_body(self) -> None:
        for body, fragment in [
            (b"{}", "to is required"),
            (b'{"to": ["a@b.c"]}', "subject"),
            (b'{"to": ["a@b.c"], "subject": "s"}', "body"),
            (b'{"to": "a@b.c", "subject": "s", "body": "x"}', "to must be"),
            (b'not json', "valid JSON"),
        ]:
            params, error = whitelist.validate_mail_body(body)
            self.assertIsNone(params, body)
            self.assertIn(fragment, error, f"{body}: {error}")

    def test_send_plain_and_html(self) -> None:
        params, error = whitelist.validate_mail_body(b'{"to": ["a@b.c"], "subject": "s", "body": "hi"}')
        self.assertEqual(error, "")
        assert params is not None
        self.assertTrue(params["isPlainText"])
        self.assertEqual(params["plainTextBody"], "hi")
        params, error = whitelist.validate_mail_body(
            b'{"to": ["a@b.c"], "subject": "s", "body": "<b>hi</b>", "html": "<b>hi</b>"}'
        )
        assert params is not None
        self.assertFalse(params["isPlainText"])
        self.assertEqual(params["body"], "<b>hi</b>")

    def test_send_empty_cc_bcc_clears_lists(self) -> None:
        params, error = whitelist.validate_mail_body(
            b'{"to": ["a@b.c"], "subject": "s", "body": "x", "cc": [], "bcc": []}'
        )
        assert params is not None
        self.assertEqual(error, "")
        self.assertEqual(params["cc"], [])
        params, error = whitelist.validate_mail_body(b'{"to": [], "subject": "s", "body": "x"}')
        self.assertIsNone(params)
        self.assertIn("to must be", error)

    def test_send_identity_id(self) -> None:
        params, error = whitelist.validate_mail_body(
            b'{"to": ["a@b.c"], "subject": "s", "body": "x", "identityId": "id2"}'
        )
        assert params is not None
        self.assertEqual(error, "")
        self.assertEqual(params["identityId"], "id2")
        params, error = whitelist.validate_mail_body(
            b'{"to": ["a@b.c"], "subject": "s", "body": "x", "identityId": 7}'
        )
        self.assertIsNone(params)
        self.assertIn("identityId must be a string", error)

    def test_update_keys(self) -> None:
        params, error = whitelist.validate_update_body(b'{"read": true, "starred": false}')
        assert params is not None
        self.assertTrue(params["read"])
        self.assertFalse(params["flagged"])
        self.assertNotIn("starred", params)
        params, error = whitelist.validate_update_body(b'{"delete": true}')
        self.assertIsNone(params)
        self.assertIn("unsupported field", error)
        params, error = whitelist.validate_update_body(b'{"read": "yes"}')
        self.assertIsNone(params)
        self.assertIn("read must be a boolean", error)
        params, error = whitelist.validate_update_body(b'{"tags": []}')
        assert params is not None
        self.assertEqual(error, "")
        self.assertEqual(params["tags"], [])
        params, error = whitelist.validate_update_body(b'{"tags": ["work", 7]}')
        self.assertIsNone(params)
        self.assertIn("tags must be an array of tag names", error)

    def test_extract_recipients(self) -> None:
        params, _ = whitelist.validate_mail_body(
            b'{"to": ["A@B.c"], "cc": ["c@d.e"], "subject": "s", "body": "x"}'
        )
        assert params is not None
        self.assertEqual(whitelist.extract_recipients(params), ["a@b.c", "c@d.e"])


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------


class TestConfig(unittest.TestCase):
    def test_defaults(self) -> None:
        env = {"PROXY_PORT": "", "COMMAND_TIMEOUT": "", "ALLOWED_SENDERS": ""}
        with patch.dict(os.environ, env, clear=False):
            module = importlib.reload(config)
        self.assertEqual(module.PORT, 8090)
        self.assertEqual(module.COMMAND_TIMEOUT, 30)
        self.assertEqual(module.ALLOWED_SENDERS, frozenset())

    def test_env_overrides(self) -> None:
        env = {"PROXY_PORT": "9999", "COMMAND_TIMEOUT": "5", "ALLOWED_SENDERS": "a@b.c, d@e.f"}
        with patch.dict(os.environ, env):
            module = importlib.reload(config)
        self.assertEqual(module.PORT, 9999)
        self.assertEqual(module.COMMAND_TIMEOUT, 5)
        self.assertEqual(module.ALLOWED_SENDERS, frozenset({"a@b.c", "d@e.f"}))

    def test_validate_requires_all_secrets(self) -> None:
        for name in ("THUNDERBIRD_PROXY_TOKEN", "THUNDERBIRD_ADDON_TOKEN", "THUNDERBIRD_ADDON_SECRET"):
            with patch.object(config, name, ""), redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    config.validate_config()
        with (
            patch.object(config, "THUNDERBIRD_PROXY_TOKEN", "tok"),
            patch.object(config, "THUNDERBIRD_ADDON_TOKEN", "addon"),
            patch.object(config, "THUNDERBIRD_ADDON_SECRET", "secret"),
        ):
            config.validate_config()  # must not raise

    def tearDown(self) -> None:
        importlib.reload(config)


# ---------------------------------------------------------------------------
# Bridge
# ---------------------------------------------------------------------------


class TestBridge(unittest.TestCase):
    def setUp(self) -> None:
        self.bridge = Bridge()

    def test_submit_without_addon_is_504(self) -> None:
        with self.assertRaises(BridgeError) as ctx:
            self.bridge.submit("accounts.list", {})
        self.assertEqual(ctx.exception.status, 504)
        self.assertIn("not connected", ctx.exception.message)

    def test_hello_enables_roundtrip(self) -> None:
        self.bridge.hello({"version": "1.0"})
        thread = threading.Thread(target=self._serve_one, args=({"ok": True, "data": {"accounts": []}},))
        thread.start()
        result = self.bridge.submit("accounts.list", {})
        thread.join()
        self.assertEqual(result, {"accounts": []})

    def _serve_one(self, reply: dict[str, Any]) -> None:
        command = self.bridge.poll(wait=5)
        assert command is not None
        self.bridge.report(command["id"], reply["ok"], reply.get("data"), reply.get("error"))

    def test_error_result_is_502(self) -> None:
        self.bridge.hello({})
        thread = threading.Thread(target=self._serve_one, args=({"ok": False, "error": "no such folder"},))
        thread.start()
        with self.assertRaises(BridgeError) as ctx:
            self.bridge.submit("message.get", {"message_id": "x"})
        thread.join()
        self.assertEqual(ctx.exception.status, 502)
        self.assertEqual(ctx.exception.message, "no such folder")

    def test_timeout_is_504(self) -> None:
        self.bridge.hello({})
        with patch.object(config, "COMMAND_TIMEOUT", 0.2):
            with self.assertRaises(BridgeError) as ctx:
                self.bridge.submit("accounts.list", {})
        self.assertIn("timed out", ctx.exception.message)

    def test_poll_times_out_to_none(self) -> None:
        self.assertIsNone(self.bridge.poll(wait=0.05))

    def test_report_unknown_id(self) -> None:
        self.assertFalse(self.bridge.report("nope", True, {}, None))

    def test_status_shape(self) -> None:
        status = self.bridge.status()
        self.assertFalse(status["connected"])
        self.assertIsNone(status["lastSeen"])
        self.bridge.hello({"thunderbird": "153.0"})
        status = self.bridge.status()
        self.assertTrue(status["connected"])
        self.assertEqual(status["addon"]["thunderbird"], "153.0")


# ---------------------------------------------------------------------------
# Live HTTP server
# ---------------------------------------------------------------------------


class _FakeAddon(threading.Thread):
    """Minimal stand-in for the Thunderbird add-on: hello, then poll/execute."""

    def __init__(self, port: int, responder: Any = None) -> None:
        super().__init__(daemon=True)
        self.port = port
        self.responder = responder or (lambda command: {"ok": True, "data": {}})
        self.stop = threading.Event()
        self.seen: list[dict[str, Any]] = []

    def _request(self, method: str, path: str, body: Any = None) -> http.client.HTTPResponse:
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=35)
        payload = json.dumps(body) if body is not None else None
        conn.request(method, path, body=payload, headers={"Authorization": f"Bearer {TEST_ADDON_TOKEN}"})
        return conn.getresponse()

    def run(self) -> None:
        self._request("POST", "/addon/hello", {"thunderbird": "153.0"}).read()
        while not self.stop.is_set():
            try:
                res = self._request("GET", "/addon/poll")
                payload = res.read()
                if res.status == 204:
                    continue
                if res.status != 200:
                    # A poll racing teardown sees the reverted token/bridge
                    # reject or return nothing — retire the thread quietly.
                    return
                command = json.loads(payload)
            except (OSError, ValueError):
                if self.stop.is_set():
                    return
                raise
            self.seen.append(command)
            reply = self.responder(command)
            self._request("POST", "/addon/result", {"id": command["id"], **reply})


class TestHTTPServer(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), ProxyHandler)
        cls.server.daemon_threads = True
        cls.port = cls.server.server_address[1]
        cls.serve_thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.serve_thread.start()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self) -> None:
        # Retire the previous test's fake add-on before starting a new one:
        # its long-poll would otherwise race to steal this test's commands.
        if TestHTTPServer.last_addon is not None:
            TestHTTPServer.last_addon.stop.set()
            TestHTTPServer.last_addon.join(2)
        patch.object(config, "THUNDERBIRD_PROXY_TOKEN", TEST_TOKEN).start()
        patch.object(config, "THUNDERBIRD_ADDON_TOKEN", TEST_ADDON_TOKEN).start()
        patch.object(config, "THUNDERBIRD_ADDON_SECRET", TEST_ADDON_SECRET).start()
        patch.object(config, "ADDON_POLL_WAIT", 0.2).start()
        patch.object(server_module, "bridge", Bridge()).start()
        self.addCleanup(patch.stopall)
        self.addon: _FakeAddon | None = None

    last_addon: _FakeAddon | None = None

    def _request(self, method: str, path: str, body: Any = None, token: str | None = TEST_TOKEN) -> tuple[int, Any]:
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        headers = {}
        if token is not None:
            headers["Authorization"] = f"Bearer {token}"
        payload = json.dumps(body) if body is not None else None
        if payload is not None:
            headers["Content-Type"] = "application/json"
        conn.request(method, path, body=payload, headers=headers)
        resp = conn.getresponse()
        data = resp.read()
        return resp.status, json.loads(data) if data else None

    def _raw(self, method: str, path: str, headers: dict[str, str] | None = None) -> tuple[int, dict[str, str]]:
        status, resp_headers, _ = self._raw_body(method, path, headers)
        return status, resp_headers

    def _raw_body(
        self, method: str, path: str, headers: dict[str, str] | None = None
    ) -> tuple[int, dict[str, str], str]:
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.request(method, path, headers=headers or {})
        resp = conn.getresponse()
        return resp.status, dict(resp.headers), resp.read().decode()

    def _start_addon(self, responder: Any = None) -> _FakeAddon:
        self.addon = _FakeAddon(self.port, responder)
        TestHTTPServer.last_addon = self.addon
        self.addon.start()
        self.addCleanup(self.addon.stop.set)
        # Wait until the hello lands so commands are never refused as offline.
        for _ in range(100):
            _, body = self._request("GET", "/status")
            if body and body["connected"]:
                break
            threading.Event().wait(0.02)
        else:
            self.fail("fake add-on did not register within 2s")
        return self.addon

    # -- token gate ---------------------------------------------------------

    def test_missing_token_401(self) -> None:
        status, body = self._request("GET", "/status", token=None)
        self.assertEqual(status, 401)
        self.assertEqual(body, {"error": "unauthorized"})

    def test_wrong_token_401(self) -> None:
        status, _ = self._request("GET", "/status", token="nope")
        self.assertEqual(status, 401)

    def test_addon_face_also_gated(self) -> None:
        status, _ = self._request("GET", "/addon/poll", token=None)
        self.assertEqual(status, 401)

    def test_agent_token_rejected_on_addon_face(self) -> None:
        status, _ = self._raw("GET", "/addon/poll", {"Authorization": f"Bearer {TEST_TOKEN}"})
        self.assertEqual(status, 401)

    def test_addon_token_rejected_on_agent_face(self) -> None:
        status, _ = self._raw("GET", "/status", {"Authorization": f"Bearer {TEST_ADDON_TOKEN}"})
        self.assertEqual(status, 401)

    # -- response signing (proxy -> add-on) -----------------------------------

    def _expected_proof(self, nonce: str, body: str) -> str:
        message = nonce.encode() + b"\n" + body.encode()
        return hmac.new(TEST_ADDON_SECRET.encode(), message, hashlib.sha256).hexdigest()

    def test_addon_status_signed(self) -> None:
        nonce = "abc123"
        status, headers, body = self._raw_body(
            "GET", "/addon/status", {"Authorization": f"Bearer {TEST_ADDON_TOKEN}", "X-Addon-Nonce": nonce}
        )
        self.assertEqual(status, 200)
        self.assertEqual(headers.get("X-Proxy-Proof"), self._expected_proof(nonce, body))

    def test_poll_empty_response_signed(self) -> None:
        nonce = "nonce-42"
        status, headers, _ = self._raw_body(
            "GET", "/addon/poll", {"Authorization": f"Bearer {TEST_ADDON_TOKEN}", "X-Addon-Nonce": nonce}
        )
        self.assertEqual(status, 204)
        self.assertEqual(headers.get("X-Proxy-Proof"), self._expected_proof(nonce, ""))

    def test_agent_face_not_signed(self) -> None:
        status, headers, _ = self._raw_body("GET", "/status", {"Authorization": f"Bearer {TEST_TOKEN}"})
        self.assertEqual(status, 200)
        self.assertNotIn("X-Proxy-Proof", headers)

    # -- CORS on the add-on face --------------------------------------------

    def test_preflight_allowed_on_addon_face(self) -> None:
        status, headers = self._raw("OPTIONS", "/addon/poll", {"Origin": "moz-extension://abc"})
        self.assertEqual(status, 204)
        self.assertEqual(headers["Access-Control-Allow-Origin"], "moz-extension://abc")
        self.assertIn("authorization", headers["Access-Control-Allow-Headers"].lower())
        self.assertIn("x-addon-nonce", headers["Access-Control-Allow-Headers"].lower())

    def test_preflight_refused_for_plain_origin(self) -> None:
        status, _ = self._raw("OPTIONS", "/status", {"Origin": "https://evil.example"})
        self.assertEqual(status, 501)

    def test_preflight_without_origin_501(self) -> None:
        status, _ = self._raw("OPTIONS", "/addon/poll", {})
        self.assertEqual(status, 501)

    def test_addon_responses_echo_moz_extension_origin(self) -> None:
        status, headers = self._raw(
            "GET", "/addon/poll", {"Origin": "moz-extension://abc", "Authorization": f"Bearer {TEST_ADDON_TOKEN}"}
        )
        self.assertEqual(status, 204)
        self.assertEqual(headers["Access-Control-Allow-Origin"], "moz-extension://abc")
        self.assertIn("X-Proxy-Proof", headers["Access-Control-Expose-Headers"])

    def test_moz_extension_origin_echoed_on_agent_face(self) -> None:
        headers = {"Origin": "moz-extension://abc", "Authorization": f"Bearer {TEST_TOKEN}"}
        status, resp_headers = self._raw("GET", "/status", headers)
        self.assertEqual(status, 200)
        self.assertEqual(resp_headers["Access-Control-Allow-Origin"], "moz-extension://abc")

    def test_plain_origin_gets_no_cors(self) -> None:
        headers = {"Origin": "https://evil.example", "Authorization": f"Bearer {TEST_TOKEN}"}
        status, resp_headers = self._raw("GET", "/status", headers)
        self.assertEqual(status, 200)
        self.assertNotIn("Access-Control-Allow-Origin", resp_headers)

    # -- routing ------------------------------------------------------------

    def test_unknown_path_404(self) -> None:
        status, body = self._request("GET", "/mail/nope/extra")
        self.assertEqual(status, 404)
        self.assertEqual(body, {"error": "endpoint not allowed"})

    def test_known_path_wrong_method_405(self) -> None:
        status, _ = self._request("POST", "/accounts")
        self.assertEqual(status, 405)

    def test_head_mirrors_status(self) -> None:
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.request("HEAD", "/status", headers={"Authorization": f"Bearer {TEST_TOKEN}"})
        resp = conn.getresponse()
        self.assertEqual(resp.status, 200)
        self.assertEqual(resp.read(), b"")

    def test_status_reports_disconnected(self) -> None:
        status, body = self._request("GET", "/status")
        self.assertEqual(status, 200)
        assert body is not None
        self.assertFalse(body["connected"])

    def test_command_without_addon_504(self) -> None:
        status, body = self._request("GET", "/accounts")
        self.assertEqual(status, 504)
        assert body is not None
        self.assertIn("not connected", body["error"])

    # -- end-to-end with the fake add-on --------------------------------------

    def test_accounts_roundtrip(self) -> None:
        addon = self._start_addon(lambda c: {"ok": True, "data": {"accounts": [{"id": "acc1"}]}})
        status, body = self._request("GET", "/accounts")
        self.assertEqual(status, 200)
        assert body is not None
        self.assertEqual(body, {"accounts": [{"id": "acc1"}]})
        for _ in range(100):
            if addon.seen:
                break
            threading.Event().wait(0.02)
        self.assertEqual(addon.seen[0]["command"], "accounts.list")

    def test_send_forwards_params(self) -> None:
        addon = self._start_addon(lambda c: {"ok": True, "data": {"sent": True}})
        status, body = self._request(
            "POST", "/mail/send", {"to": ["someone@example.com"], "subject": "hi", "body": "there"}
        )
        self.assertEqual(status, 200)
        assert body is not None
        self.assertTrue(body["sent"])
        for _ in range(100):
            if addon.seen:
                break
            threading.Event().wait(0.02)
        params = addon.seen[0]["params"]
        self.assertEqual(params["to"], ["someone@example.com"])
        self.assertEqual(params["plainTextBody"], "there")

    def test_send_validation_400_names_field(self) -> None:
        self._start_addon()
        status, body = self._request("POST", "/mail/send", {"subject": "hi", "body": "x"})
        self.assertEqual(status, 400)
        assert body is not None
        self.assertIn("to is required", body["error"])

    def test_allowed_senders_403(self) -> None:
        self._start_addon()
        with patch.object(config, "ALLOWED_SENDERS", frozenset({"friend@example.com"})):
            status, body = self._request(
                "POST", "/mail/send", {"to": ["stranger@example.com"], "subject": "s", "body": "b"}
            )
        self.assertEqual(status, 403)
        assert body is not None
        self.assertIn("stranger@example.com", body["error"])

    def test_addon_error_maps_to_502(self) -> None:
        self._start_addon(lambda c: {"ok": False, "error": "no such folder"})
        status, body = self._request("GET", "/mail/abc")
        self.assertEqual(status, 502)
        assert body is not None
        self.assertEqual(body["error"], "no such folder")

    def test_result_unknown_id_404(self) -> None:
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.request(
            "POST", "/addon/result",
            body=json.dumps({"id": "nope", "ok": True}),
            headers={"Authorization": f"Bearer {TEST_ADDON_TOKEN}"},
        )
        self.assertEqual(conn.getresponse().status, 404)

    def test_addon_unknown_path_404(self) -> None:
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.request("POST", "/addon/evil", headers={"Authorization": f"Bearer {TEST_ADDON_TOKEN}"})
        self.assertEqual(conn.getresponse().status, 404)

    def test_patch_validation_400(self) -> None:
        self._start_addon()
        status, body = self._request("PATCH", "/mail/abc", {"delete": True})
        self.assertEqual(status, 400)
        assert body is not None
        self.assertIn("unsupported field", body["error"])

    # -- logging ------------------------------------------------------------

    def test_log_line_format(self) -> None:
        capture = _LogCapture()
        config.logger.addHandler(capture)
        try:
            self._request("GET", "/status")
            # The handler logs after the response bytes go out, so the record
            # can land a moment after the client sees the reply.
            lines: list[str] = []
            for _ in range(50):
                lines = [r.getMessage() for r in capture.records]
                if any("GET /status 200 from 127.0.0.1" in line for line in lines):
                    break
                threading.Event().wait(0.02)
        finally:
            config.logger.removeHandler(capture)
        self.assertTrue(any("GET /status 200 from 127.0.0.1" in line for line in lines), lines)

    def test_shutdown_handler(self) -> None:
        probe = http.server.ThreadingHTTPServer(("127.0.0.1", 0), ProxyHandler)
        serve = threading.Thread(target=probe.serve_forever, daemon=True)
        serve.start()
        done = threading.Event()
        real_shutdown = probe.shutdown

        def wrapped() -> None:
            real_shutdown()
            done.set()

        probe.shutdown = wrapped  # type: ignore[method-assign]
        _shutdown(probe, 15, None)
        self.assertTrue(done.wait(2))
        serve.join(2)
        probe.server_close()


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
