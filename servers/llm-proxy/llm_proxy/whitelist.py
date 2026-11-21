#!/usr/bin/env python3
"""Route table and endpoint whitelist for the LLM proxy.

Each provider is a *route*: a URL prefix, an upstream target, and a
(method, path) whitelist matched against the prefix-stripped path. The wire
format is never translated — requests are passed through untouched, so each
route speaks its provider's native dialect. The only rewriting is the
optional path alias: a route may expose a tidier public prefix than the
upstream's own (all routes use '/v1'; openrouter's real prefix '/api/v1' is
restored before forwarding).

    /openrouter/v1/chat/completions  ->  https://openrouter.ai/api/v1/chat/completions
    /mlx-serve/v1/chat/completions   ->  http://host.docker.internal:11234/v1/chat/completions
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass

from . import config


@dataclass(frozen=True)
class Route:
    """One upstream provider behind the proxy."""

    name: str
    prefix: str  # URL prefix that selects this route, e.g. '/openrouter'
    target: str  # scheme://host[:port] requests are forwarded to
    allowed: list[tuple[str, re.Pattern[str]]]  # (method, compiled path pattern)
    # Optional (pattern, replacement) pairs applied to the stripped path
    # before whitelist matching and forwarding (e.g. '/v1' -> '/api/v1').
    aliases: tuple[tuple[re.Pattern[str], str], ...] = ()


def _route(
    name: str,
    prefix: str,
    target: str,
    specs: list[tuple[str, str]],
    aliases: list[tuple[str, str]] | None = None,
) -> Route:
    return Route(
        name=name,
        prefix=prefix,
        target=target,
        allowed=[(m, re.compile(p)) for m, p in specs],
        aliases=tuple((re.compile(p), r) for p, r in (aliases or [])),
    )


# ---------------------------------------------------------------------------
# Route table
# ---------------------------------------------------------------------------

OPENROUTER = _route("openrouter", "/openrouter", "https://openrouter.ai", [
    # Chat completions (streaming and non-streaming) — the inference endpoint.
    ("POST", r"^/api/v1/chat/completions$"),
    # Anthropic-Messages dialect (what pi's built-in openrouter provider uses;
    # openrouter.ai serves it at /api/v1/messages?beta=true).
    ("POST", r"^/api/v1/messages$"),
    # Model catalog (pi's /model list, cost metadata). Per spec/openrouter:
    # the catalog is flat; model details are GET /model/{author}/{slug} (singular),
    # endpoint metadata is GET /models/{author}/{slug}/endpoints. The single-
    # segment pattern additionally covers the real /models/count and /models/user.
    ("GET", r"^/api/v1/models$"),
    ("GET", r"^/api/v1/models/[^/]+$"),
    ("GET", r"^/api/v1/models/[^/]+/[^/]+/endpoints$"),
    ("GET", r"^/api/v1/model/[^/]+/[^/]+$"),
    # Provider metadata (routing/cost display).
    ("GET", r"^/api/v1/providers$"),
    # NOTE: /key and /generation are deliberately NOT whitelisted — readable
    # through the proxy's injected credential, they expose key identity, limits
    # and spend history to any caller. pi never calls them; operators can query
    # openrouter.ai/api/v1/key directly with the real key.
], aliases=[(r"^/v1(/v1)?(?=/|$)", "/api/v1")])  # public '/openrouter/v1' == upstream '/api/v1';
# the optional second '/v1' absorbs pi's built-in anthropic-messages dialect,
# whose SDK appends '/v1/messages' to a base that already ends in '/v1'.

MLX_SERVE = _route("mlx-serve", "/mlx-serve", config.MLX_SERVE_URL, [
    # OpenAI-compatible server (spec/mlx-serve/api.md). Inference surface only:
    # the two chat dialects, the model catalog, and the health check. Admin
    # routes (/v1/load-model, /v1/unload-model, /v1/models/rescan) stay out —
    # an agent must not be able to unload the model pi is running on.
    ("POST", r"^/v1/chat/completions$"),
    ("POST", r"^/v1/messages$"),  # Anthropic dialect — streaming, tools, thinking
    ("GET", r"^/v1/models$"),
    ("GET", r"^/health$"),
])

ROUTES: dict[str, Route] = {r.name: r for r in (OPENROUTER, MLX_SERVE)}


# ---------------------------------------------------------------------------
# Route resolution and whitelist matching
# ---------------------------------------------------------------------------


def resolve_route(path: str) -> tuple[str, Route, str] | None:
    """Resolve a request path to (route_name, route, forwarded_path).

    The route prefix is stripped and the route's path aliases are applied
    (e.g. openrouter's public '/v1' -> upstream '/api/v1'); query parameters
    are preserved. Returns None when no route prefix matches.
    """
    clean_path, sep, query = path.partition("?")
    for route in ROUTES.values():
        if clean_path == route.prefix or clean_path.startswith(route.prefix + "/"):
            stripped = clean_path[len(route.prefix):] or "/"
            for pattern, repl in route.aliases:
                stripped = pattern.sub(repl, stripped)
            return route.name, route, stripped + (sep + query if sep else "")
    return None


def is_allowed(route: Route, method: str, path: str) -> bool:
    """Check if (method, path) matches the route's whitelist."""
    return any(m == method and p.match(path) for m, p in route.allowed)


def path_allowed_any_method(route: Route, path: str) -> bool:
    """Check if the path is whitelisted for some other method (for 405s)."""
    return any(p.match(path) for _, p in route.allowed)


def route_enabled(name: str) -> bool:
    """A route is enabled when its credentials are present (mlx-serve needs none)."""
    if name == "openrouter":
        return bool(config.OPENROUTER_API_KEY)
    return True


# ---------------------------------------------------------------------------
# Model policy
# ---------------------------------------------------------------------------


def extract_model(body: bytes) -> str | None:
    """Extract the 'model' field from a JSON completion request body."""
    if not body:
        return None
    try:
        payload = json.loads(body)
    except ValueError:
        return None
    if isinstance(payload, dict):
        model = payload.get("model")
        if isinstance(model, str):
            return model
    return None


def is_model_allowed(model: str | None) -> bool:
    """Check the model against the ALLOWED_MODELS list (empty list = any model)."""
    return not config.ALLOWED_MODELS or model is None or model in config.ALLOWED_MODELS
