# LLM Proxy

A lightweight reverse proxy for LLM inference providers. It exposes **one host:port** for all providers, injects each provider's credentials internally, and enforces a per-route endpoint whitelist plus an optional model allowlist. Agents never see any API key.

The wire format is **never translated**: each route passes its provider's native dialect through untouched, and SSE streams are byte-copied unbuffered. The proxy is a credential broker and policy gate — model selection stays in the agent (e.g. pi's `/model`).

All routes expose a uniform `/<provider>/v1/...` prefix. Where the upstream's own path differs (OpenRouter uses `/api/v1`), a path alias restores it before forwarding — the only rewriting the proxy does.

## Routes

| Route | Public path | Method | Upstream path | Upstream | Description |
|-------|-------------|--------|---------------|----------|-------------|
| `/openrouter` | `/v1/chat/completions` | POST | `/api/v1/chat/completions` | `https://openrouter.ai` | Chat completions (streaming + non-streaming). Injects the OpenRouter key as a Bearer token. |
| `/openrouter` | `/v1/messages` | POST | `/api/v1/messages` | | Anthropic-Messages dialect — pi's built-in openrouter provider uses it; from a `/v1` base its SDK sends `/v1/v1/messages`, which the alias collapses. `?beta=true` allowed. |
| `/openrouter` | `/v1/models` | GET | `/api/v1/models` | | Model catalog |
| `/openrouter` | `/v1/models/count`, `/v1/models/user` | GET | `/api/v1/models/count`, `/api/v1/models/user` | | Model count / user models |
| `/openrouter` | `/v1/model/{author}/{slug}` | GET | `/api/v1/model/{author}/{slug}` | | Model details (singular `model`, per spec) |
| `/openrouter` | `/v1/models/{author}/{slug}/endpoints` | GET | `/api/v1/models/{author}/{slug}/endpoints` | | Model endpoint metadata |
| `/openrouter` | `/v1/providers` | GET | `/api/v1/providers` | | Provider metadata |

> `/key` and `/generation` are **not** whitelisted: reached through the proxy's injected credential they expose key identity, spending limits and request history to any caller. pi never needs them — query openrouter.ai directly with the real key for account info.
| `/mlx-serve` | `/v1/chat/completions` | POST | *(same)* | `http://host.docker.internal:11234` (env `MLX_SERVE_URL`) | OpenAI-compatible completions on the local model server. Client auth is stripped. |
| `/mlx-serve` | `/v1/messages` | POST | *(same)* | | Anthropic dialect — streaming, tool calling, extended thinking. |
| `/mlx-serve` | `/v1/models` | GET | *(same)* | | Model catalog (loaded models + capabilities) |
| `/mlx-serve` | `/health` | GET | *(same)* | | Health check |

The mlx-serve route deliberately omits the server's admin surface — `POST /v1/load-model`, `POST /v1/unload-model` and `POST /v1/models/rescan` would let an agent unload the very model pi is running on.

The route prefix is stripped before forwarding, so `/openrouter/v1/chat/completions` → `https://openrouter.ai/api/v1/chat/completions` (alias) and `/mlx-serve/v1/models` → `http://host.docker.internal:11234/v1/models` (pass-through). The upstream-native form (`/openrouter/api/v1/...`) is accepted too. Unknown prefixes and non-whitelisted paths return **404**; a whitelisted path with the wrong method returns **405**. The `/openrouter` route is disabled (404) while `OPENROUTER_API_KEY` is unset.

## Setup

```bash
cd servers/llm-proxy

# 1. Set your OpenRouter key (optional — only the /openrouter route needs it)
echo "sk-or-v1-your-key-here" > secrets/openrouter-api-key.txt

# 2. Optional: shared-secret gate so other host processes can't ride the proxy.
#    When present, every request must send 'Authorization: Bearer <token>'.
echo "some-random-token" > secrets/llm-proxy-token.txt

# 3. Build and run
./scripts/build-docker.sh
./scripts/run-docker.sh

# Proxy is now at http://localhost:8089
```

## Configuration (env vars)

| Variable | Default | Purpose |
|----------|---------|---------|
| `PROXY_PORT` | `8089` | Listen port |
| `OPENROUTER_API_KEY` | — | Injected into `/openrouter` requests; empty disables the route |
| `MLX_SERVE_URL` | `http://host.docker.internal:11234` | mlx-serve route target |
| `LLM_PROXY_TOKEN` | — | Optional client gate (see above) |
| `ALLOWED_MODELS` | _(any)_ | Comma-separated model allowlist for `/chat/completions` (applies to all routes) |
| `LLM_UPSTREAM_TIMEOUT` | `600` | Upstream read timeout (seconds) — long, for reasoning models |

## Security posture — open by default (deliberate)

With `LLM_PROXY_TOKEN` unset the proxy authenticates **no one**: anything that can reach the port may spend through the injected credentials. This is a conscious default for a single-user host whose only consumers are agents you control — the same posture the github-proxy takes with its PAT — and it holds because of *reach*, not authentication:

- Compose publishes `127.0.0.1:8089` only — nothing off the machine can connect.
- Everything **local** can: any host process, and containers with host access (pia via `host.docker.internal`). That is the trust you are extending.
- Browsers largely cannot ride it: JSON `POST`s trigger a CORS preflight the proxy never answers, and form-encoded fallbacks are rejected upstream.

What the open port cannot bound by itself is a *misbehaving or compromised agent* burning credits. The bound belongs at the provider: **use a dedicated openrouter key with a small per-key spend limit** for this proxy. Enable the token (`secrets/llm-proxy-token.txt`) the moment the box is shared, long-running, or reachable beyond localhost — and give the client the same value: `LLM_PROXY_TOKEN` on the pia container (the provider extension sends it as the Bearer credential on every request; see *Wiring pi to it*), or `"apiKey": "<token>"` in a plain `models.json` setup.

## Wiring pi to it

The pia harness wires pi to the proxy with a **single provider extension** —
`harnesses/pia/extensions/llm-proxy.ts`, installed into
`~/.pi/agent/extensions/` — and **no `models.json` at all**. It registers
both providers in one place:

- `openrouter` — a `baseUrl` **override of pi's built-in provider**
  (`${LLM_PROXY_URL}/openrouter/v1`); the built-in catalog, thinking-level
  maps, `~latest` virtual models, per-key filtering and Anthropic-dialect
  handling are all preserved.
- `mlx-serve` — a native **dynamic** provider whose catalog is discovered
  live from `/mlx-serve/v1/models` (issue #14).

Configuration is two container env vars, mirrored on the proxy side:
`LLM_PROXY_URL` (base URL, default `http://host.docker.internal:8089`) and
the optional gate token — set `LLM_PROXY_TOKEN` to the **same value** on both
sides; pi then sends it as the Bearer credential on every request, the proxy
validates it and swaps in the real provider key. With the token unset the
extension sends the dummy `"none"`, matching the proxy's default open posture.

For setups without the extension, plain `models.json` still works — the
harness gets one host, dummy keys, and keeps its own model picker:

```json
{
  "providers": {
    "openrouter": {
      "baseUrl": "http://host.docker.internal:8089/openrouter/v1",
      "apiKey": "none"
    },
    "mlx-serve": {
      "baseUrl": "http://host.docker.internal:8089/mlx-serve/v1",
      "api": "openai-completions",
      "apiKey": "none",
      "models": [ ... ]
    }
  }
}
```

With `LLM_PROXY_TOKEN` set, use `"apiKey": "<token>"` instead — pi sends it as a Bearer header and the proxy validates it, then swaps in the real provider credential.

The `openrouter` entry above is a **built-in provider override**, not a custom provider: pi keeps its built-in catalog (context windows, thinking levels, per-key filtering) and only the endpoint changes. Its `baseUrl` ends in `/openrouter/v1` because pi speaks *two* dialects to OpenRouter through that one base — the OpenAI implementation appends `/chat/completions`, the Anthropic SDK appends `/v1/messages` — and the route's alias normalizes both (`/v1/v1/...` collapses to `/api/v1/...`). A custom provider (like `mlx-serve`) is different: pi knows nothing about it, so its `models` must be declared explicitly with metadata — the static `models` list above is the no-extension fallback; the extension above replaces it with live discovery from the proxy's catalog.

## Logging

Every request logs to stderr in the repo's proxy format, enriched with the model and (for non-streaming responses) token usage:

```
[proxy] 2026-07-27T13:48:54Z POST /openrouter/v1/chat/completions 200 from 127.0.0.1 tokens=10+2 model=openai/gpt-4o
[proxy] 2026-07-27T13:49:00Z POST /mlx-serve/v1/chat/completions 200 from 127.0.0.1 stream model=qwen/qwen3.6-35b-a3b
```

## Tests

```bash
python3 -m unittest tests.test_server -v
```

## Spec

- `spec/openrouter/openapi.yaml` — the upstream OpenAPI document (server root `https://openrouter.ai/api/v1`).
- `spec/mlx-serve/api.md` — the HTTP API reference from the [ddalcu/mlx-serve](https://github.com/ddalcu/mlx-serve) repo (`docs/api.md`, fetched from commit `9e3311c21743`); the project ships no OpenAPI file.

Both route whitelists are aligned against these documents. The whitelists intentionally cover only the inference and read-only catalog surface: OpenRouter account surfaces (`/key`, `/keys`, `/credits`, `/guardrails`, `/batches`, `/workspaces`, …) and mlx-serve model-lifecycle routes (`/v1/load-model`, `/v1/unload-model`, `/v1/models/rescan`) stay unlisted and return 404 — anything that leaks key identity, budget or spend through the injected credential is operator-only.
