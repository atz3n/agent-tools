#!/usr/bin/env python3
"""Tests for the PR-only GitHub API proxy server."""

from __future__ import annotations

import logging
import os
import unittest
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
        self.assertTrue(whitelist.is_pr_endpoint('/repos/owner/repo/pulls'))
        self.assertTrue(whitelist.is_pr_endpoint('/repos/octocat/Hello-World/pulls'))

    def test_list_pull_requests_with_query_params_allowed(self) -> None:
        """GET /repos/{owner}/{repo}/pulls?state=open should be allowed."""
        self.assertTrue(whitelist.is_pr_endpoint('/repos/owner/repo/pulls?state=open'))
        self.assertTrue(whitelist.is_pr_endpoint('/repos/owner/repo/pulls?state=closed&sort=created'))

    def test_get_pull_request_allowed(self) -> None:
        """GET /repos/{owner}/{repo}/pulls/{number} should be allowed."""
        self.assertTrue(whitelist.is_pr_endpoint('/repos/owner/repo/pulls/1'))
        self.assertTrue(whitelist.is_pr_endpoint('/repos/owner/repo/pulls/123'))
        self.assertTrue(whitelist.is_pr_endpoint('/repos/owner/repo/pulls/999999'))

    def test_update_pull_request_allowed(self) -> None:
        """PATCH /repos/{owner}/{repo}/pulls/{number} should be allowed."""
        self.assertTrue(whitelist.is_pr_endpoint('/repos/owner/repo/pulls/42'))

    def test_delete_pull_request_allowed(self) -> None:
        """DELETE /repos/{owner}/{repo}/pulls/{number} should be allowed."""
        self.assertTrue(whitelist.is_pr_endpoint('/repos/owner/repo/pulls/42'))

    def test_create_pull_request_allowed(self) -> None:
        """POST /repos/{owner}/{repo}/pulls should be allowed."""
        self.assertTrue(whitelist.is_pr_endpoint('/repos/owner/repo/pulls'))

    def test_list_review_comments_allowed(self) -> None:
        """GET /repos/{owner}/{repo}/pulls/{number}/comments should be allowed."""
        self.assertTrue(whitelist.is_pr_endpoint('/repos/owner/repo/pulls/42/comments'))

    def test_create_review_comment_allowed(self) -> None:
        """POST /repos/{owner}/{repo}/pulls/{number}/comments should be allowed."""
        self.assertTrue(whitelist.is_pr_endpoint('/repos/owner/repo/pulls/42/comments'))

    def test_get_review_comment_allowed(self) -> None:
        """GET /repos/{owner}/{repo}/pulls/{number}/comments/{id} should be allowed."""
        self.assertTrue(whitelist.is_pr_endpoint('/repos/owner/repo/pulls/42/comments/123'))
        self.assertTrue(whitelist.is_pr_endpoint('/repos/owner/repo/pulls/42/comments/999999'))

    def test_update_review_comment_allowed(self) -> None:
        """PATCH /repos/{owner}/{repo}/pulls/{number}/comments/{id} should be allowed."""
        self.assertTrue(whitelist.is_pr_endpoint('/repos/owner/repo/pulls/42/comments/123'))

    def test_list_reviews_allowed(self) -> None:
        """GET /repos/{owner}/{repo}/pulls/{number}/reviews should be allowed."""
        self.assertTrue(whitelist.is_pr_endpoint('/repos/owner/repo/pulls/42/reviews'))

    def test_create_review_allowed(self) -> None:
        """POST /repos/{owner}/{repo}/pulls/{number}/reviews should be allowed."""
        self.assertTrue(whitelist.is_pr_endpoint('/repos/owner/repo/pulls/42/reviews'))

    def test_get_review_allowed(self) -> None:
        """GET /repos/{owner}/{repo}/pulls/{number}/reviews/{id} should be allowed."""
        self.assertTrue(whitelist.is_pr_endpoint('/repos/owner/repo/pulls/42/reviews/123'))

    def test_update_review_allowed(self) -> None:
        """PUT /repos/{owner}/{repo}/pulls/{number}/reviews/{id} should be allowed."""
        self.assertTrue(whitelist.is_pr_endpoint('/repos/owner/repo/pulls/42/reviews/123'))

    def test_delete_pending_review_allowed(self) -> None:
        """DELETE /repos/{owner}/{repo}/pulls/{number}/reviews/{id} should be allowed."""
        self.assertTrue(whitelist.is_pr_endpoint('/repos/owner/repo/pulls/42/reviews/123'))

    def test_dismiss_review_allowed(self) -> None:
        """PUT /repos/{owner}/{repo}/pulls/{number}/reviews/{id}/dismissals should be allowed."""
        self.assertTrue(whitelist.is_pr_endpoint('/repos/owner/repo/pulls/42/reviews/123/dismissals'))

    def test_submit_review_allowed(self) -> None:
        """POST /repos/{owner}/{repo}/pulls/{number}/reviews/{id}/events should be allowed."""
        self.assertTrue(whitelist.is_pr_endpoint('/repos/owner/repo/pulls/42/reviews/123/events'))

    def test_merge_pull_request_allowed(self) -> None:
        """PUT /repos/{owner}/{repo}/pulls/{number}/merge should be allowed."""
        self.assertTrue(whitelist.is_pr_endpoint('/repos/owner/repo/pulls/42/merge'))

    def test_list_pr_commits_allowed(self) -> None:
        """GET /repos/{owner}/{repo}/pulls/{number}/commits should be allowed."""
        self.assertTrue(whitelist.is_pr_endpoint('/repos/owner/repo/pulls/42/commits'))

    def test_list_pr_files_allowed(self) -> None:
        """GET /repos/{owner}/{repo}/pulls/{number}/files should be allowed."""
        self.assertTrue(whitelist.is_pr_endpoint('/repos/owner/repo/pulls/42/files'))

    def test_update_pr_branch_allowed(self) -> None:
        """PUT /repos/{owner}/{repo}/pulls/{number}/update-branch should be allowed."""
        self.assertTrue(whitelist.is_pr_endpoint('/repos/owner/repo/pulls/42/update-branch'))

    def test_get_authenticated_user_allowed(self) -> None:
        """GET /user should be allowed."""
        self.assertTrue(whitelist.is_pr_endpoint('/user'))

    def test_list_prs_with_commit_allowed(self) -> None:
        """GET /repos/{owner}/{repo}/commits/{sha}/pulls should be allowed."""
        self.assertTrue(whitelist.is_pr_endpoint('/repos/owner/repo/commits/abc123def/pulls'))

    def test_list_review_comments_in_repo_allowed(self) -> None:
        """GET /repos/{owner}/{repo}/pulls/comments should be allowed."""
        self.assertTrue(whitelist.is_pr_endpoint('/repos/owner/repo/pulls/comments'))

    def test_list_review_comments_in_repo_with_query_allowed(self) -> None:
        """GET /repos/{owner}/{repo}/pulls/comments?sort=created should be allowed."""
        self.assertTrue(whitelist.is_pr_endpoint('/repos/owner/repo/pulls/comments?sort=created'))

    def test_review_comment_reactions_allowed(self) -> None:
        """GET/POST /repos/{owner}/{repo}/pulls/comments/{id}/reactions should be allowed."""
        self.assertTrue(whitelist.is_pr_endpoint('/repos/owner/repo/pulls/comments/123/reactions'))

    def test_review_comment_reaction_allowed(self) -> None:
        """GET/DELETE /repos/{owner}/{repo}/pulls/comments/{id}/reactions/{reaction_id} should be allowed."""
        self.assertTrue(whitelist.is_pr_endpoint('/repos/owner/repo/pulls/comments/123/reactions/456'))

    def test_pr_discussion_comments_allowed(self) -> None:
        """GET/POST /repos/{owner}/{repo}/issues/{number}/comments should be allowed (PR discussion comments)."""
        self.assertTrue(whitelist.is_pr_endpoint('/repos/owner/repo/issues/5/comments'))
        self.assertTrue(whitelist.is_pr_endpoint('/repos/owner/repo/issues/42/comments'))
        self.assertTrue(whitelist.is_pr_endpoint('/repos/owner/repo/issues/123/comments'))

    def test_pr_discussion_comments_with_query_params_allowed(self) -> None:
        """PR discussion comments with query params should be allowed."""
        self.assertTrue(whitelist.is_pr_endpoint('/repos/owner/repo/issues/5/comments?sort=updated'))


class TestBlockedEndpoints(unittest.TestCase):
    """Test that non-PR endpoints are properly blocked."""

    def test_issues_endpoint_blocked(self) -> None:
        """GET /repos/{owner}/{repo}/issues should still be blocked (only /issues/{n}/comments is allowed)."""
        self.assertFalse(whitelist.is_pr_endpoint('/repos/owner/repo/issues'))

    def test_repos_endpoint_blocked(self) -> None:
        """GET /repos/{owner}/{repo} should be blocked."""
        self.assertFalse(whitelist.is_pr_endpoint('/repos/owner/repo'))

    def test_branches_endpoint_blocked(self) -> None:
        """GET /repos/{owner}/{repo}/branches should be blocked."""
        self.assertFalse(whitelist.is_pr_endpoint('/repos/owner/repo/branches'))

    def test_commits_endpoint_blocked(self) -> None:
        """GET /repos/{owner}/{repo}/commits should be blocked."""
        self.assertFalse(whitelist.is_pr_endpoint('/repos/owner/repo/commits'))

    def test_users_endpoint_blocked(self) -> None:
        """GET /users/{username} should be blocked."""
        self.assertFalse(whitelist.is_pr_endpoint('/users/octocat'))

    def test_root_endpoint_blocked(self) -> None:
        """GET / should be blocked."""
        self.assertFalse(whitelist.is_pr_endpoint('/'))

    def test_app_endpoint_blocked(self) -> None:
        """GET /app should be blocked."""
        self.assertFalse(whitelist.is_pr_endpoint('/app'))

    def test_pulls_extra_path_segment_blocked(self) -> None:
        """GET /repos/{owner}/{repo}/pulls/123/extra should be blocked."""
        self.assertFalse(whitelist.is_pr_endpoint('/repos/owner/repo/pulls/123/extra'))

    def test_user_extra_path_segment_blocked(self) -> None:
        """GET /user/settings should be blocked."""
        self.assertFalse(whitelist.is_pr_endpoint('/user/settings'))

    def test_user_with_trailing_slash_blocked(self) -> None:
        """GET /user/ should be blocked."""
        self.assertFalse(whitelist.is_pr_endpoint('/user/'))

    def test_non_existent_pr_path_blocked(self) -> None:
        """GET /repos/{owner}/{repo}/nonexistent should be blocked."""
        self.assertFalse(whitelist.is_pr_endpoint('/repos/owner/repo/nonexistent'))

    def test_orgs_endpoint_blocked(self) -> None:
        """GET /orgs/{org} should be blocked."""
        self.assertFalse(whitelist.is_pr_endpoint('/orgs/octocat'))

    def test_gists_endpoint_blocked(self) -> None:
        """GET /gists should be blocked."""
        self.assertFalse(whitelist.is_pr_endpoint('/gists'))

    def test_search_endpoint_blocked(self) -> None:
        """GET /search/repositories should be blocked."""
        self.assertFalse(whitelist.is_pr_endpoint('/search/repositories'))

    def test_notifications_endpoint_blocked(self) -> None:
        """GET /notifications should be blocked."""
        self.assertFalse(whitelist.is_pr_endpoint('/notifications'))

    def test_labels_endpoint_blocked(self) -> None:
        """GET /repos/{owner}/{repo}/labels should be blocked."""
        self.assertFalse(whitelist.is_pr_endpoint('/repos/owner/repo/labels'))

    def test_milestones_endpoint_blocked(self) -> None:
        """GET /repos/{owner}/{repo}/milestones should be blocked."""
        self.assertFalse(whitelist.is_pr_endpoint('/repos/owner/repo/milestones'))

    def test_projects_endpoint_blocked(self) -> None:
        """GET /repos/{owner}/{repo}/projects should be blocked."""
        self.assertFalse(whitelist.is_pr_endpoint('/repos/owner/repo/projects'))

    def test_tags_endpoint_blocked(self) -> None:
        """GET /repos/{owner}/{repo}/tags should be blocked."""
        self.assertFalse(whitelist.is_pr_endpoint('/repos/owner/repo/tags'))

    def test_releases_endpoint_blocked(self) -> None:
        """GET /repos/{owner}/{repo}/releases should be blocked."""
        self.assertFalse(whitelist.is_pr_endpoint('/repos/owner/repo/releases'))

    def test_actions_endpoint_blocked(self) -> None:
        """GET /repos/{owner}/{repo}/actions/secrets should be blocked."""
        self.assertFalse(whitelist.is_pr_endpoint('/repos/owner/repo/actions/secrets'))

    def test_checks_endpoint_blocked(self) -> None:
        """GET /repos/{owner}/{repo}/check-runs should be blocked."""
        self.assertFalse(whitelist.is_pr_endpoint('/repos/owner/repo/check-runs'))

    def test_deployments_endpoint_blocked(self) -> None:
        """GET /repos/{owner}/{repo}/deployments should be blocked."""
        self.assertFalse(whitelist.is_pr_endpoint('/repos/owner/repo/deployments'))

    def test_packages_endpoint_blocked(self) -> None:
        """GET /packages should be blocked."""
        self.assertFalse(whitelist.is_pr_endpoint('/packages'))

    def test_marketplace_endpoint_blocked(self) -> None:
        """GET /marketplace_listing should be blocked."""
        self.assertFalse(whitelist.is_pr_endpoint('/marketplace_listing'))

    def test_rate_limit_endpoint_blocked(self) -> None:
        """GET /rate_limit should be blocked."""
        self.assertFalse(whitelist.is_pr_endpoint('/rate_limit'))

    def test_meta_endpoint_blocked(self) -> None:
        """GET /meta should be blocked."""
        self.assertFalse(whitelist.is_pr_endpoint('/meta'))

    def test_emoticons_endpoint_blocked(self) -> None:
        """GET /emoticons should be blocked."""
        self.assertFalse(whitelist.is_pr_endpoint('/emoticons'))

    def test_gitignore_templates_endpoint_blocked(self) -> None:
        """GET /gitignore/templates should be blocked."""
        self.assertFalse(whitelist.is_pr_endpoint('/gitignore/templates'))

    def test_licenses_endpoint_blocked(self) -> None:
        """GET /licenses should be blocked."""
        self.assertFalse(whitelist.is_pr_endpoint('/licenses'))

    def test_markdown_endpoint_blocked(self) -> None:
        """POST /markdown should be blocked."""
        self.assertFalse(whitelist.is_pr_endpoint('/markdown'))

    def test_emojis_endpoint_blocked(self) -> None:
        """GET /emojis should be blocked."""
        self.assertFalse(whitelist.is_pr_endpoint('/emojis'))


class TestQueryParameterStripping(unittest.TestCase):
    """Test that query parameters are properly stripped for endpoint matching."""

    def test_simple_query_param(self) -> None:
        """Query params should be stripped before matching."""
        self.assertTrue(whitelist.is_pr_endpoint('/repos/owner/repo/pulls?state=open'))

    def test_multiple_query_params(self) -> None:
        """Multiple query params should be stripped before matching."""
        self.assertTrue(whitelist.is_pr_endpoint('/repos/owner/repo/pulls?state=open&sort=created&direction=desc'))

    def test_pr_with_query_params(self) -> None:
        """PR endpoint with query params should be allowed."""
        self.assertTrue(whitelist.is_pr_endpoint('/repos/owner/repo/pulls/42?expand=true'))

    def test_review_comments_with_query_params(self) -> None:
        """Review comments endpoint with query params should be allowed."""
        self.assertTrue(whitelist.is_pr_endpoint('/repos/owner/repo/pulls/42/comments?sort=updated'))

    def test_reviews_with_query_params(self) -> None:
        """Reviews endpoint with query params should be allowed."""
        self.assertTrue(whitelist.is_pr_endpoint('/repos/owner/repo/pulls/42/reviews?per_page=50'))

    def test_empty_query_param(self) -> None:
        """Empty query string should still match."""
        self.assertTrue(whitelist.is_pr_endpoint('/repos/owner/repo/pulls?'))

    def test_special_chars_in_query_params(self) -> None:
        """Special characters in query params should not affect matching."""
        self.assertTrue(whitelist.is_pr_endpoint('/repos/owner/repo/pulls?state=open&labels=bug%2Cfeature'))


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


if __name__ == '__main__':
    unittest.main()
