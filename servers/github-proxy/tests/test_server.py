#!/usr/bin/env python3
"""Tests for the PR-only GitHub API proxy server."""

from __future__ import annotations

import http.client
import io
import logging
import os
import unittest
from email.message import Message
from unittest.mock import MagicMock, patch

from github_proxy import (  # noqa: E402
    config,  # noqa: E402
    whitelist,  # noqa: E402
)
from github_proxy import server as _server  # noqa: E402
from github_proxy.server import ProxyHandler, _shutdown  # noqa: E402


class _LogCapture(logging.Handler):
    """Captures log records for testing."""

    def __init__(self) -> None:
        super().__init__()
        self.records: list[logging.LogRecord] = []

    def emit(self, record: logging.LogRecord) -> None:
        self.records.append(record)


class TestEndpointWhitelist(unittest.TestCase):
    """Test the PR endpoint whitelist regex patterns."""

    def test_list_pull_requests_allowed(self) -> None:
        """GET /repos/{owner}/{repo}/pulls should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/pulls'))
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/octocat/Hello-World/pulls'))

    def test_list_pull_requests_with_query_params_allowed(self) -> None:
        """GET /repos/{owner}/{repo}/pulls?state=open should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/pulls?state=open'))
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/pulls?state=closed&sort=created'))

    def test_get_pull_request_allowed(self) -> None:
        """GET /repos/{owner}/{repo}/pulls/{number} should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/pulls/1'))
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/pulls/123'))
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/pulls/999999'))

    def test_update_pull_request_allowed(self) -> None:
        """PATCH /repos/{owner}/{repo}/pulls/{number} should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/pulls/42'))

    def test_delete_pull_request_allowed(self) -> None:
        """DELETE /repos/{owner}/{repo}/pulls/{number} should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/pulls/42'))

    def test_create_pull_request_allowed(self) -> None:
        """POST /repos/{owner}/{repo}/pulls should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/pulls'))

    def test_list_review_comments_allowed(self) -> None:
        """GET /repos/{owner}/{repo}/pulls/{number}/comments should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/pulls/42/comments'))

    def test_create_review_comment_allowed(self) -> None:
        """POST /repos/{owner}/{repo}/pulls/{number}/comments should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/pulls/42/comments'))

    def test_get_review_comment_allowed(self) -> None:
        """GET /repos/{owner}/{repo}/pulls/{number}/comments/{id} should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/pulls/42/comments/123'))
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/pulls/42/comments/999999'))

    def test_update_review_comment_allowed(self) -> None:
        """PATCH /repos/{owner}/{repo}/pulls/{number}/comments/{id} should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/pulls/42/comments/123'))

    def test_list_reviews_allowed(self) -> None:
        """GET /repos/{owner}/{repo}/pulls/{number}/reviews should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/pulls/42/reviews'))

    def test_create_review_allowed(self) -> None:
        """POST /repos/{owner}/{repo}/pulls/{number}/reviews should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/pulls/42/reviews'))

    def test_get_review_allowed(self) -> None:
        """GET /repos/{owner}/{repo}/pulls/{number}/reviews/{id} should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/pulls/42/reviews/123'))

    def test_update_review_allowed(self) -> None:
        """PUT /repos/{owner}/{repo}/pulls/{number}/reviews/{id} should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/pulls/42/reviews/123'))

    def test_delete_pending_review_allowed(self) -> None:
        """DELETE /repos/{owner}/{repo}/pulls/{number}/reviews/{id} should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/pulls/42/reviews/123'))

    def test_dismiss_review_allowed(self) -> None:
        """PUT /repos/{owner}/{repo}/pulls/{number}/reviews/{id}/dismissals should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/pulls/42/reviews/123/dismissals'))

    def test_submit_review_allowed(self) -> None:
        """POST /repos/{owner}/{repo}/pulls/{number}/reviews/{id}/events should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/pulls/42/reviews/123/events'))

    def test_merge_pull_request_allowed(self) -> None:
        """PUT /repos/{owner}/{repo}/pulls/{number}/merge should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/pulls/42/merge'))

    def test_list_pr_commits_allowed(self) -> None:
        """GET /repos/{owner}/{repo}/pulls/{number}/commits should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/pulls/42/commits'))

    def test_list_pr_files_allowed(self) -> None:
        """GET /repos/{owner}/{repo}/pulls/{number}/files should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/pulls/42/files'))

    def test_update_pr_branch_allowed(self) -> None:
        """PUT /repos/{owner}/{repo}/pulls/{number}/update-branch should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/pulls/42/update-branch'))

    def test_get_authenticated_user_allowed(self) -> None:
        """GET /user should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/user'))

    def test_list_prs_with_commit_allowed(self) -> None:
        """GET /repos/{owner}/{repo}/commits/{sha}/pulls should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/commits/abc123def/pulls'))

    def test_list_review_comments_in_repo_allowed(self) -> None:
        """GET /repos/{owner}/{repo}/pulls/comments should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/pulls/comments'))

    def test_list_review_comments_in_repo_with_query_allowed(self) -> None:
        """GET /repos/{owner}/{repo}/pulls/comments?sort=created should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/pulls/comments?sort=created'))

    def test_review_comment_reactions_allowed(self) -> None:
        """GET/POST /repos/{owner}/{repo}/pulls/comments/{id}/reactions should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/pulls/comments/123/reactions'))

    def test_review_comment_reaction_allowed(self) -> None:
        """GET/DELETE /repos/{owner}/{repo}/pulls/comments/{id}/reactions/{reaction_id} should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/pulls/comments/123/reactions/456'))

    def test_pr_discussion_comments_allowed(self) -> None:
        """GET/POST /repos/{owner}/{repo}/issues/{number}/comments should be allowed (PR discussion comments)."""
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/issues/5/comments'))
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/issues/42/comments'))
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/issues/123/comments'))

    def test_pr_discussion_comments_with_query_params_allowed(self) -> None:
        """PR discussion comments with query params should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/issues/5/comments?sort=updated'))


class TestIssueEndpoints(unittest.TestCase):
    """Test the issue endpoint whitelist regex patterns."""

    def test_list_issues_allowed(self) -> None:
        """GET /repos/{owner}/{repo}/issues should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/issues'))
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/octocat/Hello-World/issues'))

    def test_list_issues_with_query_params_allowed(self) -> None:
        """GET /repos/{owner}/{repo}/issues?state=open should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/issues?state=open'))
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/issues?state=closed&labels=bug%2Cfeature'))

    def test_create_issue_allowed(self) -> None:
        """POST /repos/{owner}/{repo}/issues should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/issues'))

    def test_get_issue_allowed(self) -> None:
        """GET /repos/{owner}/{repo}/issues/{number} should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/issues/1'))
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/issues/999999'))

    def test_update_issue_allowed(self) -> None:
        """PATCH /repos/{owner}/{repo}/issues/{number} should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/issues/42'))

    def test_issue_comments_allowed(self) -> None:
        """Issue comment collection and single-comment paths should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/issues/42/comments'))
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/issues/42/comments/123'))

    def test_issue_labels_allowed(self) -> None:
        """Issue label collection and per-label paths should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/issues/42/labels'))
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/issues/42/labels/bug'))

    def test_issue_assignees_allowed(self) -> None:
        """GET/POST/DELETE /repos/{owner}/{repo}/issues/{number}/assignees should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/issues/42/assignees'))

    def test_repository_labels_allowed(self) -> None:
        """GET /repos/{owner}/{repo}/labels should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/labels'))

    def test_issue_extra_path_segment_blocked(self) -> None:
        """Unknown sub-paths under /issues/{number} should be blocked."""
        self.assertFalse(whitelist.is_allowed_endpoint('/repos/owner/repo/issues/42/events'))
        self.assertFalse(whitelist.is_allowed_endpoint('/repos/owner/repo/issues/42/timeline'))
        self.assertFalse(whitelist.is_allowed_endpoint('/repos/owner/repo/issues/42/lock'))
        self.assertFalse(whitelist.is_allowed_endpoint('/repos/owner/repo/issues/42/reactions'))

    def test_repository_label_item_blocked(self) -> None:
        """/repos/{owner}/{repo}/labels/{name} (label CRUD) should be blocked."""
        self.assertFalse(whitelist.is_allowed_endpoint('/repos/owner/repo/labels/bug'))


class TestBlockedEndpoints(unittest.TestCase):
    """Test that non-PR/issue endpoints are properly blocked."""

    def test_repos_endpoint_blocked(self) -> None:
        """GET /repos/{owner}/{repo} should be blocked."""
        self.assertFalse(whitelist.is_allowed_endpoint('/repos/owner/repo'))

    def test_branches_endpoint_blocked(self) -> None:
        """GET /repos/{owner}/{repo}/branches should be blocked."""
        self.assertFalse(whitelist.is_allowed_endpoint('/repos/owner/repo/branches'))

    def test_commits_endpoint_blocked(self) -> None:
        """GET /repos/{owner}/{repo}/commits should be blocked."""
        self.assertFalse(whitelist.is_allowed_endpoint('/repos/owner/repo/commits'))

    def test_users_endpoint_blocked(self) -> None:
        """GET /users/{username} should be blocked."""
        self.assertFalse(whitelist.is_allowed_endpoint('/users/octocat'))

    def test_root_endpoint_blocked(self) -> None:
        """GET / should be blocked."""
        self.assertFalse(whitelist.is_allowed_endpoint('/'))

    def test_app_endpoint_blocked(self) -> None:
        """GET /app should be blocked."""
        self.assertFalse(whitelist.is_allowed_endpoint('/app'))

    def test_pulls_extra_path_segment_blocked(self) -> None:
        """GET /repos/{owner}/{repo}/pulls/123/extra should be blocked."""
        self.assertFalse(whitelist.is_allowed_endpoint('/repos/owner/repo/pulls/123/extra'))

    def test_user_extra_path_segment_blocked(self) -> None:
        """GET /user/settings should be blocked."""
        self.assertFalse(whitelist.is_allowed_endpoint('/user/settings'))

    def test_user_with_trailing_slash_blocked(self) -> None:
        """GET /user/ should be blocked."""
        self.assertFalse(whitelist.is_allowed_endpoint('/user/'))

    def test_non_existent_pr_path_blocked(self) -> None:
        """GET /repos/{owner}/{repo}/nonexistent should be blocked."""
        self.assertFalse(whitelist.is_allowed_endpoint('/repos/owner/repo/nonexistent'))

    def test_orgs_endpoint_blocked(self) -> None:
        """GET /orgs/{org} should be blocked."""
        self.assertFalse(whitelist.is_allowed_endpoint('/orgs/octocat'))

    def test_gists_endpoint_blocked(self) -> None:
        """GET /gists should be blocked."""
        self.assertFalse(whitelist.is_allowed_endpoint('/gists'))

    def test_search_endpoint_blocked(self) -> None:
        """GET /search/repositories should be blocked."""
        self.assertFalse(whitelist.is_allowed_endpoint('/search/repositories'))

    def test_notifications_endpoint_blocked(self) -> None:
        """GET /notifications should be blocked."""
        self.assertFalse(whitelist.is_allowed_endpoint('/notifications'))

    def test_repository_label_item_endpoint_blocked(self) -> None:
        """PATCH /repos/{owner}/{repo}/labels/{name} should be blocked (only the labels list is allowed)."""
        self.assertFalse(whitelist.is_allowed_endpoint('/repos/owner/repo/labels/bug'))

    def test_milestones_endpoint_blocked(self) -> None:
        """GET /repos/{owner}/{repo}/milestones should be blocked."""
        self.assertFalse(whitelist.is_allowed_endpoint('/repos/owner/repo/milestones'))

    def test_projects_endpoint_blocked(self) -> None:
        """GET /repos/{owner}/{repo}/projects should be blocked."""
        self.assertFalse(whitelist.is_allowed_endpoint('/repos/owner/repo/projects'))

    def test_tags_endpoint_blocked(self) -> None:
        """GET /repos/{owner}/{repo}/tags should be blocked."""
        self.assertFalse(whitelist.is_allowed_endpoint('/repos/owner/repo/tags'))

    def test_releases_endpoint_blocked(self) -> None:
        """GET /repos/{owner}/{repo}/releases should be blocked."""
        self.assertFalse(whitelist.is_allowed_endpoint('/repos/owner/repo/releases'))

    def test_actions_endpoint_blocked(self) -> None:
        """GET /repos/{owner}/{repo}/actions/secrets should be blocked."""
        self.assertFalse(whitelist.is_allowed_endpoint('/repos/owner/repo/actions/secrets'))

    def test_checks_endpoint_blocked(self) -> None:
        """GET /repos/{owner}/{repo}/check-runs should be blocked."""
        self.assertFalse(whitelist.is_allowed_endpoint('/repos/owner/repo/check-runs'))

    def test_deployments_endpoint_blocked(self) -> None:
        """GET /repos/{owner}/{repo}/deployments should be blocked."""
        self.assertFalse(whitelist.is_allowed_endpoint('/repos/owner/repo/deployments'))

    def test_packages_endpoint_blocked(self) -> None:
        """GET /packages should be blocked."""
        self.assertFalse(whitelist.is_allowed_endpoint('/packages'))

    def test_marketplace_endpoint_blocked(self) -> None:
        """GET /marketplace_listing should be blocked."""
        self.assertFalse(whitelist.is_allowed_endpoint('/marketplace_listing'))

    def test_rate_limit_endpoint_blocked(self) -> None:
        """GET /rate_limit should be blocked."""
        self.assertFalse(whitelist.is_allowed_endpoint('/rate_limit'))

    def test_meta_endpoint_blocked(self) -> None:
        """GET /meta should be blocked."""
        self.assertFalse(whitelist.is_allowed_endpoint('/meta'))

    def test_emoticons_endpoint_blocked(self) -> None:
        """GET /emoticons should be blocked."""
        self.assertFalse(whitelist.is_allowed_endpoint('/emoticons'))

    def test_gitignore_templates_endpoint_blocked(self) -> None:
        """GET /gitignore/templates should be blocked."""
        self.assertFalse(whitelist.is_allowed_endpoint('/gitignore/templates'))

    def test_licenses_endpoint_blocked(self) -> None:
        """GET /licenses should be blocked."""
        self.assertFalse(whitelist.is_allowed_endpoint('/licenses'))

    def test_markdown_endpoint_blocked(self) -> None:
        """POST /markdown should be blocked."""
        self.assertFalse(whitelist.is_allowed_endpoint('/markdown'))

    def test_emojis_endpoint_blocked(self) -> None:
        """GET /emojis should be blocked."""
        self.assertFalse(whitelist.is_allowed_endpoint('/emojis'))


class TestQueryParameterStripping(unittest.TestCase):
    """Test that query parameters are properly stripped for endpoint matching."""

    def test_simple_query_param(self) -> None:
        """Query params should be stripped before matching."""
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/pulls?state=open'))

    def test_multiple_query_params(self) -> None:
        """Multiple query params should be stripped before matching."""
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/pulls?state=open&sort=created&direction=desc'))

    def test_pr_with_query_params(self) -> None:
        """PR endpoint with query params should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/pulls/42?expand=true'))

    def test_review_comments_with_query_params(self) -> None:
        """Review comments endpoint with query params should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/pulls/42/comments?sort=updated'))

    def test_reviews_with_query_params(self) -> None:
        """Reviews endpoint with query params should be allowed."""
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/pulls/42/reviews?per_page=50'))

    def test_empty_query_param(self) -> None:
        """Empty query string should still match."""
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/pulls?'))

    def test_special_chars_in_query_params(self) -> None:
        """Special characters in query params should not affect matching."""
        self.assertTrue(whitelist.is_allowed_endpoint('/repos/owner/repo/pulls?state=open&labels=bug%2Cfeature'))


class TestConfiguration(unittest.TestCase):
    """Test configuration loading."""

    def test_target_url(self) -> None:
        """TARGET should be set to GitHub API URL."""
        self.assertEqual(config.TARGET, "https://api.github.com")

    def test_default_port(self) -> None:
        """Default PORT should be 8086."""
        self.assertEqual(config.PORT, 8086)

    def test_token_from_env(self) -> None:
        """TOKEN should be loaded from environment variable."""
        with patch.dict(os.environ, {'GITHUB_PERSONAL_ACCESS_TOKEN': 'test_token_123'}):
            import importlib
            importlib.reload(config)
            self.assertEqual(config.TOKEN, 'test_token_123')

    def test_token_empty_when_not_set(self) -> None:
        """TOKEN should be empty string when env var is not set."""
        with patch.dict(os.environ, {'GITHUB_PERSONAL_ACCESS_TOKEN': ''}, clear=True):
            import importlib
            importlib.reload(config)
            self.assertEqual(config.TOKEN, '')


class TestLogFunction(unittest.TestCase):
    """Test the logger."""

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
        config.logger.info("GET /user 200")
        self.assertEqual(len(self._capture.records), 1)
        self.assertIn('GET', self._capture.records[0].getMessage())
        self.assertIn('/user', self._capture.records[0].getMessage())
        self.assertIn('200', self._capture.records[0].getMessage())

    def test_log_includes_client_ip(self) -> None:
        """Log message should include client IP when provided."""
        config.logger.info("GET /user 200 from 192.168.1.1")
        msg = self._capture.records[0].getMessage()
        self.assertIn('192.168.1.1', msg)
        self.assertIn('from', msg)

    def test_log_includes_timestamp(self) -> None:
        """Log message should include ISO 8601 timestamp."""
        config.logger.info("GET /user 200")
        self.assertRegex(
            self._capture.records[0].asctime,
            r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z',
        )


class TestTokenValidation(unittest.TestCase):
    """Test token validation."""

    def test_validate_token_with_token(self) -> None:
        """validate_token should not exit when token is set."""
        with patch.dict(os.environ, {'GITHUB_PERSONAL_ACCESS_TOKEN': 'test_token'}):
            import importlib
            importlib.reload(config)
            # Should not raise
            config.validate_token()

    def test_validate_token_without_token(self) -> None:
        """validate_token should exit when token is not set."""
        with patch.dict(os.environ, {'GITHUB_PERSONAL_ACCESS_TOKEN': ''}, clear=True):
            import importlib
            importlib.reload(config)
            with self.assertRaises(SystemExit) as ctx:
                config.validate_token()
            self.assertEqual(ctx.exception.code, 1)


class TestServerIntegration(unittest.TestCase):
    """Integration tests for the server (without starting actual server)."""

    def test_handler_creation(self) -> None:
        """ProxyHandler should be a valid class."""
        from http.server import BaseHTTPRequestHandler
        self.assertTrue(issubclass(ProxyHandler, BaseHTTPRequestHandler))

    def test_http_methods_supported(self) -> None:
        """All HTTP methods should be supported."""
        handler_methods = ['do_GET', 'do_POST', 'do_PATCH', 'do_PUT', 'do_DELETE']
        for method in handler_methods:
            self.assertTrue(hasattr(ProxyHandler, method))

    def test_log_message_method_exists(self) -> None:
        """log_message method should exist."""
        self.assertTrue(hasattr(ProxyHandler, 'log_message'))


class TestGracefulShutdown(unittest.TestCase):
    """Test graceful shutdown signal handling."""

    def test_signal_module_imported(self) -> None:
        """Server module should import the signal module."""
        self.assertTrue(hasattr(_server, 'signal'))

    def test_shutdown_handler_exists(self) -> None:
        """Server should define _shutdown function for signal handling."""
        self.assertTrue(hasattr(_shutdown, '__call__'))

    def test_shutdown_handler_calls_server_shutdown(self) -> None:
        """_shutdown handler should call server.shutdown()."""
        mock_server = MagicMock()
        _shutdown(mock_server, 0, None)
        mock_server.shutdown.assert_called_once()


class TestProxyForwarding(unittest.TestCase):
    """Test the core _proxy() logic: forwarding, auth injection, header handling."""

    def setUp(self) -> None:
        """Set up a fake connection mock for every test."""
        self.mock_conn_cls = MagicMock()
        self.conn = MagicMock()
        self.mock_conn_cls.return_value = self.conn
        self.resp = MagicMock()
        self.resp.status = 200
        self.resp.read.return_value = b'{"ok": true}'
        self.resp.getheaders.return_value = [("Content-Type", "application/json")]
        self.conn.getresponse.return_value = self.resp
        self._patcher = patch(
            'github_proxy.server.http.client.HTTPSConnection', self.mock_conn_cls
        )
        self._patcher.start()

    def tearDown(self) -> None:
        """Stop the HTTPSConnection patch."""
        self._patcher.stop()

    @staticmethod
    def _make_handler(
        path: str,
        headers: dict[str, str] | list[tuple[str, str]] | None = None,
        body: bytes = b'',
    ) -> ProxyHandler:
        """Build a ProxyHandler without running the real request handshake."""
        handler = ProxyHandler.__new__(ProxyHandler)
        handler.path = path
        handler.command = 'GET'
        handler.request_version = 'HTTP/1.1'
        handler.requestline = f'GET {path} HTTP/1.1'
        handler.client_address = ('192.168.1.100', 54321)
        msg = Message()
        items = headers.items() if isinstance(headers, dict) else (headers or [])
        for key, value in items:
            msg[key] = value
        msg['Content-Length'] = str(len(body))
        handler.headers = msg
        handler.rfile = io.BytesIO(body)
        handler.wfile = io.BytesIO()
        return handler

    @staticmethod
    def _parse_response(raw: bytes) -> tuple[int, dict[str, str], bytes]:
        """Split the raw HTTP response written to wfile into status, headers, body."""
        head, _, body = raw.partition(b'\r\n\r\n')
        lines = head.split(b'\r\n')
        status = int(lines[0].split(b' ')[1])
        headers: dict[str, str] = {}
        for line in lines[1:]:
            key, _, value = line.partition(b': ')
            headers[key.decode().lower()] = value.decode()
        return status, headers, body

    @staticmethod
    def _output(handler: ProxyHandler) -> bytes:
        """Return everything the handler wrote to wfile."""
        assert isinstance(handler.wfile, io.BytesIO)
        return handler.wfile.getvalue()

    def _forwarded(self) -> tuple[str, str, bytes | None, dict[str, str]]:
        """Return (method, path, body, headers) passed to conn.request."""
        args, kwargs = self.conn.request.call_args
        return args[0], args[1], kwargs.get('body'), kwargs.get('headers')

    # --- 403 rejection over HTTP -------------------------------------------

    def test_blocked_path_returns_403(self) -> None:
        """A non-whitelisted path should return 403 with a JSON error body."""
        handler = self._make_handler('/repos/o/r/branches')
        handler._proxy('GET')
        status, headers, body = self._parse_response(self._output(handler))
        self.assertEqual(status, 403)
        self.assertEqual(headers['content-type'], 'application/json')
        self.assertIn(b'endpoint not allowed', body)

    def test_blocked_path_never_connects_to_github(self) -> None:
        """A blocked path must not open a connection to the backend."""
        handler = self._make_handler('/repos/o/r/branches')
        handler._proxy('GET')
        self.mock_conn_cls.assert_not_called()
        self.conn.request.assert_not_called()

    # --- request forwarding ---------------------------------------------------

    def test_allowed_path_forwards_raw_path_with_query(self) -> None:
        """Whitelist matching strips query params, but forwarding keeps them."""
        handler = self._make_handler('/repos/o/r/pulls?state=open&per_page=10')
        handler._proxy('GET')
        _, path, _, _ = self._forwarded()
        self.assertEqual(path, '/repos/o/r/pulls?state=open&per_page=10')

    def test_body_is_forwarded(self) -> None:
        """Request body should be read via Content-Length and forwarded."""
        body = b'{"title": "My PR"}'
        handler = self._make_handler(
            '/repos/o/r/pulls', {'Content-Type': 'application/json'}, body
        )
        handler._proxy('POST')
        method, _, sent_body, _ = self._forwarded()
        self.assertEqual(method, 'POST')
        self.assertEqual(sent_body, body)

    def test_connection_targets_configured_host(self) -> None:
        """HTTPSConnection should be created for api.github.com on port 443."""
        handler = self._make_handler('/user')
        handler._proxy('GET')
        self.mock_conn_cls.assert_called_once_with('api.github.com', 443, timeout=30)

    # --- auth injection -------------------------------------------------------

    def test_authorization_injected(self) -> None:
        """The proxy token should be injected as a Bearer authorization header."""
        handler = self._make_handler('/user')
        with patch('github_proxy.server.TOKEN', 'proxy_secret'):
            handler._proxy('GET')
        _, _, _, headers = self._forwarded()
        self.assertEqual(headers['authorization'], 'Bearer proxy_secret')

    def test_client_authorization_is_overridden(self) -> None:
        """A client-supplied Authorization header must never reach GitHub."""
        handler = self._make_handler(
            '/user', {'Authorization': 'Bearer client_token'}
        )
        with patch('github_proxy.server.TOKEN', 'proxy_secret'):
            handler._proxy('GET')
        _, _, _, headers = self._forwarded()
        self.assertEqual(headers['authorization'], 'Bearer proxy_secret')
        self.assertNotIn('client_token', headers['authorization'])

    def test_host_header_rewritten(self) -> None:
        """The Host header must be rewritten to api.github.com."""
        handler = self._make_handler('/user', {'Host': 'localhost:8086'})
        handler._proxy('GET')
        _, _, _, headers = self._forwarded()
        self.assertEqual(headers['host'], 'api.github.com')

    # --- header handling --------------------------------------------------------

    def test_duplicate_accept_headers_merged(self) -> None:
        """Duplicate Accept headers should be combined into one comma-separated value."""
        handler = self._make_handler(
            '/user',
            [('Accept', 'application/json'), ('Accept', 'application/vnd.github+json')],
        )
        handler._proxy('GET')
        _, _, _, headers = self._forwarded()
        self.assertEqual(
            headers['accept'], 'application/json, application/vnd.github+json'
        )

    def test_hop_by_hop_headers_stripped_from_request(self) -> None:
        """connection/keep-alive/transfer-encoding must not be forwarded."""
        handler = self._make_handler(
            '/user',
            {
                'Connection': 'keep-alive',
                'Keep-Alive': 'timeout=5',
                'Transfer-Encoding': 'chunked',
                'X-Custom': 'kept',
            },
        )
        handler._proxy('GET')
        _, _, _, headers = self._forwarded()
        for hop in ('connection', 'keep-alive', 'transfer-encoding'):
            self.assertNotIn(hop, headers)
        self.assertEqual(headers['x-custom'], 'kept')

    def test_default_user_agent_set(self) -> None:
        """A default User-Agent should be set when the client sends none."""
        handler = self._make_handler('/user')
        handler._proxy('GET')
        _, _, _, headers = self._forwarded()
        self.assertEqual(headers['user-agent'], 'pr-proxy/1.0')

    def test_client_user_agent_preserved(self) -> None:
        """A client-supplied User-Agent should not be overwritten."""
        handler = self._make_handler('/user', {'User-Agent': 'my-agent/2.0'})
        handler._proxy('GET')
        _, _, _, headers = self._forwarded()
        self.assertEqual(headers['user-agent'], 'my-agent/2.0')

    # --- response relay ---------------------------------------------------------

    def test_response_status_and_body_relayed(self) -> None:
        """Backend status and body should be passed through to the client."""
        self.resp.status = 201
        self.resp.read.return_value = b'{"number": 42}'
        handler = self._make_handler('/repos/o/r/pulls')
        handler._proxy('POST')
        status, _, body = self._parse_response(self._output(handler))
        self.assertEqual(status, 201)
        self.assertEqual(body, b'{"number": 42}')

    def test_response_hop_by_hop_headers_filtered(self) -> None:
        """Hop-by-hop headers from the backend must not be relayed to the client."""
        self.resp.getheaders.return_value = [
            ('Content-Type', 'application/json'),
            ('Transfer-Encoding', 'chunked'),
            ('Connection', 'keep-alive'),
        ]
        handler = self._make_handler('/user')
        handler._proxy('GET')
        _, headers, _ = self._parse_response(self._output(handler))
        self.assertEqual(headers['content-type'], 'application/json')
        self.assertNotIn('transfer-encoding', headers)
        self.assertNotIn('connection', headers)

    def test_connection_closed_after_relay(self) -> None:
        """The backend connection should be closed after the response is relayed."""
        handler = self._make_handler('/user')
        handler._proxy('GET')
        self.conn.close.assert_called_once()

    # --- HTTP method delegation ---------------------------------------------------

    def test_all_http_methods_delegate_to_proxy(self) -> None:
        """do_GET/POST/PATCH/PUT/DELETE should each call _proxy with their method."""
        handler = self._make_handler('/user')
        calls: list[str] = []
        handler._proxy = calls.append  # type: ignore[method-assign]
        handler.do_GET()
        handler.do_POST()
        handler.do_PATCH()
        handler.do_PUT()
        handler.do_DELETE()
        self.assertEqual(calls, ['GET', 'POST', 'PATCH', 'PUT', 'DELETE'])

    # --- backend failure (documents current behavior) ------------------------------

    def test_backend_connection_failure_propagates(self) -> None:
        """KNOWN GAP: backend errors currently escape the handler unhandled.

        This test documents current behavior; if _proxy() later gains proper
        502/504 error handling, this test should be updated to assert on it.
        """
        self.conn.request.side_effect = http.client.RemoteDisconnected('closed')
        handler = self._make_handler('/user')
        with self.assertRaises(http.client.RemoteDisconnected):
            handler._proxy('GET')


if __name__ == '__main__':
    unittest.main()
