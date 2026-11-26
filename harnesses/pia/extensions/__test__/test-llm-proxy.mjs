#!/usr/bin/env node
/**
 * Unit tests for the llm-proxy provider extension.
 *
 * Runs with plain node (type stripping is on by default in node >= 23.6):
 *   node --test harnesses/pia/extensions/__test__/
 *
 * The pi packages are dependencies of the globally installed pi, not of this
 * repo, so a resolve hook maps the bare specifiers onto the installed dist
 * files. Their own imports resolve normally from inside pi's node_modules.
 */

import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { test } from "node:test";
import { pathToFileURL } from "node:url";

const PI_MODULES = "/usr/local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/@earendil-works";
const SPECIFIER_MAP = {
	"@earendil-works/pi-ai": `${PI_MODULES}/pi-ai/dist/index.js`,
	"@earendil-works/pi-ai/compat": `${PI_MODULES}/pi-ai/dist/compat.js`,
	"@earendil-works/pi-coding-agent": `${PI_MODULES}/pi-coding-agent/dist/index.js`,
};
registerHooks({
	resolve(specifier, context, nextResolve) {
		const target = SPECIFIER_MAP[specifier];
		if (target) return { url: pathToFileURL(target).href, shortCircuit: true };
		return nextResolve(specifier, context);
	},
});

const EXTENSION_URL = new URL("../llm-proxy.ts", import.meta.url).href;

/** Catalog shaped like the real GET /v1/models response through llm-proxy. */
const CATALOG = {
	object: "list",
	data: [
		{
			id: "ddalcu/Qwen3.8-Flash-Next-MLX-Serve-iQ-MLX-4.7bpw",
			state: "ready",
			capabilities: ["chat", "tool_use", "streaming", "vision", "reasoning", "json_schema"],
			input_modalities: ["text", "image", "video"],
			context_length: 262144,
			agent_budget: { context: 262144, output: 65536, compaction_reserve: 20000 },
		},
		{ id: "Runpod/FLUX.2-klein-4B-mflux-4bit", state: "unloaded", capabilities: ["image"], context_length: 0 },
		{ id: "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit", state: "unloaded", capabilities: ["audio"] },
		{
			id: "ddalcu/Qwen3.8-27B-MLX-Serve-8bit",
			state: "unloaded",
			capabilities: ["chat", "tool_use", "streaming", "json_schema"],
			input_modalities: ["text"],
			context_length: 262144,
			agent_budget: { context: 262144, output: 65536 },
		},
	],
};

/** Mock fetch; returns a function with `.requests` and configurable behaviour. */
function mockFetch(handler) {
	const requests = [];
	const fn = async (url, options = {}) => {
		requests.push({ url, options });
		return handler(url, options);
	};
	fn.requests = requests;
	return fn;
}

const okResponse = (body) => ({
	ok: true,
	status: 200,
	json: async () => body,
});

/** Load the extension fresh and collect every registerProvider call. */
async function loadAndRegister(fetchImpl) {
	const previousFetch = globalThis.fetch;
	globalThis.fetch = fetchImpl;
	const registrations = [];
	try {
		const { default: extensionFactory } = await import(`${EXTENSION_URL}?case=${Math.random()}`);
		await extensionFactory({
			registerProvider: (nameOrProvider, config) => {
				registrations.push({ name: typeof nameOrProvider === "string" ? nameOrProvider : nameOrProvider.id, nameOrProvider, config });
			},
		});
	} finally {
		globalThis.fetch = previousFetch;
	}
	const openrouter = registrations.find((entry) => entry.name === "openrouter");
	const mlxServe = registrations.find((entry) => entry.name === "mlx-serve");
	return { registrations, openrouter, mlxProvider: mlxServe?.nameOrProvider };
}

function refreshContext({ allowNetwork = true, stored, signal = new AbortController().signal } = {}) {
	const publications = [];
	return {
		publications,
		context: {
			credential: undefined,
			stored,
			publish: async (publication) => {
				publications.push(publication);
				publication.update?.();
				return true;
			},
			allowNetwork,
			force: allowNetwork || undefined,
			signal,
			baseUrl: "http://test.local/mlx-serve/v1",
		},
	};
}

// ─── openrouter override ─────────────────────────────────────────────────────

test("registers the openrouter built-in override against the proxy", async () => {
	const { openrouter } = await loadAndRegister(mockFetch(async () => okResponse(CATALOG)));
	assert.ok(openrouter, "openrouter must be registered by the extension");
	assert.equal(openrouter.config.baseUrl, "http://host.docker.internal:8089/openrouter/v1");
	assert.equal(openrouter.config.apiKey, "none", "dummy credential by default");
	// An override must NOT carry a model list — pi keeps the built-in catalog.
	assert.equal(openrouter.config.models, undefined);
});

test("LLM_PROXY_TOKEN becomes the openrouter override credential", async () => {
	process.env.LLM_PROXY_TOKEN = "s3cret-gate";
	try {
		const { openrouter, mlxProvider } = await loadAndRegister(mockFetch(async () => okResponse(CATALOG)));
		assert.equal(openrouter.config.apiKey, "s3cret-gate");
		const resolved = await mlxProvider.auth.apiKey.resolve({ ctx: {}, signal: new AbortController().signal });
		assert.equal(resolved.auth.apiKey, "s3cret-gate", "mlx-serve sends the same gate token");
	} finally {
		delete process.env.LLM_PROXY_TOKEN;
	}
});

// ─── mlx-serve dynamic provider ──────────────────────────────────────────────

test("registers the mlx-serve provider with a startup-fetched baseline", async () => {
	const { mlxProvider } = await loadAndRegister(mockFetch(async () => okResponse(CATALOG)));
	assert.equal(mlxProvider.id, "mlx-serve");
	assert.equal(mlxProvider.name, "MLX Serve (llm-proxy)");
	assert.equal(mlxProvider.baseUrl, "http://host.docker.internal:8089/mlx-serve/v1");
	// Non-chat models filtered out, both chat models present.
	assert.deepEqual(
		mlxProvider.getModels().map((model) => model.id),
		[
			"ddalcu/Qwen3.8-Flash-Next-MLX-Serve-iQ-MLX-4.7bpw",
			"ddalcu/Qwen3.8-27B-MLX-Serve-8bit",
		],
	);
	assert.ok(mlxProvider.refreshModels, "provider must be dynamic (refreshModels present)");
	assert.ok(mlxProvider.auth.apiKey, "provider must expose apiKey auth so refreshes run");
});

test("startup fetch failure retries, then registers an empty baseline", async () => {
	const failing = mockFetch(async () => {
		throw new TypeError("fetch failed: ECONNREFUSED");
	});
	const { mlxProvider } = await loadAndRegister(failing);
	assert.equal(mlxProvider.id, "mlx-serve");
	assert.deepEqual(mlxProvider.getModels(), []);
	assert.equal(failing.requests.length, 2, "a failed baseline fetch is retried once");
});

test("a retried baseline fetch recovers when the first attempt fails", async () => {
	let calls = 0;
	const { mlxProvider } = await loadAndRegister(
		mockFetch(async () => {
			calls += 1;
			if (calls === 1) throw new TypeError("fetch failed: EAI_AGAIN host.docker.internal");
			return okResponse(CATALOG);
		}),
	);
	assert.equal(mlxProvider.getModels().length, 2, "retry fills the baseline after a transient DNS failure");
});

test("a hanging startup fetch is cut off by the timeout and registers an empty baseline", async () => {
	const started = Date.now();
	const hanging = mockFetch(
		(_url, options) =>
			new Promise((_, reject) =>
				options.signal.addEventListener("abort", () => reject(options.signal.reason)),
			),
	);
	const { mlxProvider } = await loadAndRegister(hanging);
	assert.deepEqual(mlxProvider.getModels(), [], "unreachable catalog must not block startup");
	assert.equal(hanging.requests.length, 2, "the timed-out attempt is retried once");
	// STARTUP_FETCH_TIMEOUT_MS is 5000 with 2 attempts — boot may not wait
	// longer than that (plus slack) for a catalog that never answers.
	assert.ok(Date.now() - started < 12_000, `startup took ${Date.now() - started}ms`);
});

test("maps catalog entries onto pi chat model fields", async () => {
	const { mlxProvider } = await loadAndRegister(mockFetch(async () => okResponse(CATALOG)));
	const [ready, unloaded] = mlxProvider.getModels();

	assert.equal(ready.type, "chat");
	assert.equal(ready.name, "Qwen3.8-Flash-Next-MLX-Serve-iQ-MLX-4.7bpw");
	assert.equal(ready.api, "openai-completions");
	assert.equal(ready.provider, "mlx-serve");
	assert.equal(ready.baseUrl, "http://host.docker.internal:8089/mlx-serve/v1");
	assert.equal(ready.reasoning, true);
	// "video" is not a pi chat input modality and must be dropped.
	assert.deepEqual(ready.input, ["text", "image"]);
	assert.equal(ready.contextWindow, 262144);
	assert.equal(ready.maxTokens, 65536);
	assert.deepEqual(ready.cost, { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 });

	assert.equal(unloaded.reasoning, false, "no reasoning capability -> reasoning false");
	assert.deepEqual(unloaded.input, ["text"]);
});

test("ready models sort before unloaded ones", async () => {
	const { mlxProvider } = await loadAndRegister(mockFetch(async () => okResponse(CATALOG)));
	// The catalog lists the unloaded chat model second; readiness must keep the
	// ready one first regardless of id order.
	assert.equal(mlxProvider.getModels()[0].id, "ddalcu/Qwen3.8-Flash-Next-MLX-Serve-iQ-MLX-4.7bpw");
});

test("refreshModels fetches the catalog, publishes and persists it", async () => {
	const { mlxProvider } = await loadAndRegister(mockFetch(async () => okResponse(CATALOG)));
	const fetchImpl = mockFetch(async () => okResponse(CATALOG));
	globalThis.fetch = fetchImpl;
	try {
		const { publications, context } = refreshContext();
		await mlxProvider.refreshModels(context);
		assert.equal(fetchImpl.requests.length, 1);
		assert.equal(fetchImpl.requests[0].url, "http://host.docker.internal:8089/mlx-serve/v1/models");
		assert.equal(fetchImpl.requests[0].options.signal, context.signal, "must honour the abort signal");
		assert.equal(publications.length, 1);
		assert.ok(publications[0].persist, "network refresh must persist the catalog for print mode");
		assert.equal(publications[0].persist.models.length, 2);
		assert.ok(publications[0].persist.checkedAt > 0);
		assert.equal(mlxProvider.getModels().length, 2);
	} finally {
		delete globalThis.fetch;
	}
});

test("offline refresh pass restores the stored catalog without network access", async () => {
	const { mlxProvider } = await loadAndRegister(mockFetch(async () => okResponse(CATALOG)));
	const storedModel = {
		type: "chat",
		id: "stored/model-a",
		name: "model-a",
		api: "openai-completions",
		provider: "mlx-serve",
		baseUrl: "http://host.docker.internal:8089/mlx-serve/v1",
		reasoning: false,
		input: ["text"],
		cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
		contextWindow: 128000,
		maxTokens: 8192,
	};
	const fetchImpl = mockFetch(async () => okResponse(CATALOG));
	globalThis.fetch = fetchImpl;
	try {
		const { context } = refreshContext({ allowNetwork: false, stored: { models: [storedModel], checkedAt: 1 } });
		await mlxProvider.refreshModels(context);
		assert.equal(fetchImpl.requests.length, 0, "offline pass must not touch the network");
		// createProvider overlays restored dynamic models on the static baseline.
		assert.ok(
			mlxProvider.getModels().some((model) => model.id === "stored/model-a"),
			"stored catalog restored in print mode without network",
		);
	} finally {
		delete globalThis.fetch;
	}
});

test("a failing refresh keeps the last known list and does not clear models", async () => {
	const { mlxProvider } = await loadAndRegister(mockFetch(async () => okResponse(CATALOG)));
	globalThis.fetch = mockFetch(async () => ({ ok: false, status: 502, json: async () => ({}) }));
	try {
		const { publications, context } = refreshContext();
		await assert.rejects(() => mlxProvider.refreshModels(context), /HTTP 502/);
		assert.equal(publications.length, 0, "failed refresh publishes nothing");
		assert.equal(mlxProvider.getModels().length, 2, "previous list retained");
	} finally {
		delete globalThis.fetch;
	}
});

test("catalog discovery carries the gate credential", async () => {
	const fetchImpl = mockFetch(async () => okResponse(CATALOG));
	await loadAndRegister(fetchImpl);
	assert.equal(fetchImpl.requests[0].options.headers.Authorization, "Bearer none", "dummy by default");

	process.env.LLM_PROXY_TOKEN = "gate-test";
	try {
		const gated = mockFetch(async () => okResponse(CATALOG));
		await loadAndRegister(gated);
		assert.equal(gated.requests[0].options.headers.Authorization, "Bearer gate-test");
	} finally {
		delete process.env.LLM_PROXY_TOKEN;
	}
});

test("LLM_PROXY_URL drives both providers' base urls", async () => {
	process.env.LLM_PROXY_URL = "http://localhost:8089";
	try {
		const { openrouter, mlxProvider } = await loadAndRegister(mockFetch(async () => okResponse(CATALOG)));
		assert.equal(openrouter.config.baseUrl, "http://localhost:8089/openrouter/v1");
		assert.equal(mlxProvider.baseUrl, "http://localhost:8089/mlx-serve/v1");
		assert.equal(mlxProvider.getModels()[0].baseUrl, "http://localhost:8089/mlx-serve/v1");
	} finally {
		delete process.env.LLM_PROXY_URL;
	}
});
