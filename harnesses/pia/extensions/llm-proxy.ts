/**
 * llm-proxy provider extension for pi (pia image) — one place for all
 * inference wiring.
 *
 * Registers both providers that reach inference through the llm-proxy
 * (default: http://host.docker.internal:8089), so no models.json is needed
 * and the proxy base URL is configured once:
 *
 *   LLM_PROXY_URL    llm-proxy base URL (appended with /openrouter/v1 and
 *                    /mlx-serve/v1). Default: http://host.docker.internal:8089
 *   LLM_PROXY_TOKEN  optional shared-secret gate, must match the proxy's
 *                    LLM_PROXY_TOKEN. Sent as the Bearer credential on every
 *                    request; the proxy validates it, then injects the real
 *                    provider key (or strips auth for credential-free
 *                    routes). Unset -> dummy "none", the proxy's default
 *                    open posture.
 *
 * Provider 1: openrouter — a baseUrl override of pi's BUILT-IN provider.
 * Only the endpoint changes: pi keeps its curated catalog (context windows,
 * thinking-level maps, virtual `~latest` models, per-key filtering) and the
 * Anthropic-dialect path for Claude models. Do not copy the model list here.
 *
 * Provider 2: mlx-serve — a native dynamic provider. Discovers chat models
 * from mlx-serve's catalog (GET /mlx-serve/v1/models, proxied), so loading
 * or renaming a local model no longer requires a config edit and an image
 * rebuild. Why a native provider with `fetchModels` instead of a static
 * models.json list:
 * - pi persists what `fetchModels` returns to the model store and restores
 *   it on the next startup's offline refresh pass. Print mode
 *   (`pi --print`, which `pia ask` uses) never refreshes catalogs, so
 *   without persistence a print session would only ever see the empty list.
 * - A failed fetch keeps the previous list and never stalls startup.
 * - The async factory additionally performs one best-effort fetch at load
 *   time, so even a fresh container with an empty model store has a catalog
 *   in print mode. If mlx-serve is down, startup waits at most
 *   STARTUP_FETCH_TIMEOUT_MS and registers an empty baseline.
 *
 * Streaming is delegated to pi's built-in `openai-completions`
 * implementation — no custom stream code.
 */

import { createProvider, type Model, type RefreshModelsContext } from "@earendil-works/pi-ai";
import { openAICompletionsApi } from "@earendil-works/pi-ai/compat";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const PROVIDER_ID = "mlx-serve";
const BASE = process.env.LLM_PROXY_URL ?? "http://host.docker.internal:8089";
const BASE_URL = `${BASE}/mlx-serve/v1`;
const CATALOG_URL = `${BASE_URL}/models`;

/** Bearer credential for every llm-proxy route; matches the proxy's LLM_PROXY_TOKEN gate. */
const PROXY_TOKEN = process.env.LLM_PROXY_TOKEN ?? "none";

/** Cap on how long the load-time catalog fetch may delay pi startup. */
const STARTUP_FETCH_TIMEOUT_MS = 3000;

/** Fallbacks for catalog entries that omit budget/context metadata. */
const DEFAULT_CONTEXT_WINDOW = 128_000;
const DEFAULT_MAX_TOKENS = 8_192;

/** Shape of one entry in mlx-serve's GET /v1/models response (subset). */
interface MlxServeCatalogEntry {
	id: string;
	state?: string;
	capabilities?: string[];
	input_modalities?: string[];
	context_length?: number;
	agent_budget?: { context?: number; output?: number; compaction_reserve?: number };
}

function toChatModel(entry: MlxServeCatalogEntry): Model<"openai-completions"> | null {
	const capabilities = Array.isArray(entry.capabilities) ? entry.capabilities : [];
	// The catalog also lists FLUX/LTX/Hunyuan3D/TTS models; only chat models
	// are usable through /v1/chat/completions.
	if (!capabilities.includes("chat")) return null;

	// pi's chat input modalities are text/image only; mlx-serve also reports
	// "video", which the wire format carries as image_url parts — drop it.
	const input = (Array.isArray(entry.input_modalities) ? entry.input_modalities : []).filter(
		(modality) => modality === "text" || modality === "image",
	);

	return {
		type: "chat",
		id: entry.id,
		name: entry.id.split("/").pop() ?? entry.id,
		api: "openai-completions",
		provider: PROVIDER_ID,
		baseUrl: BASE_URL,
		reasoning: capabilities.includes("reasoning"),
		input: input.length > 0 ? (input as ("text" | "image")[]) : ["text"],
		cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
		contextWindow: entry.context_length && entry.context_length > 0 ? entry.context_length : DEFAULT_CONTEXT_WINDOW,
		maxTokens: entry.agent_budget?.output && entry.agent_budget.output > 0 ? entry.agent_budget.output : DEFAULT_MAX_TOKENS,
	};
}

/**
 * Fetch the live catalog. Models whose engine is ready sort before unloaded
 * ones (an unloaded model still works — mlx-serve loads it on request — but
 * the first token takes as long as the load). Throws on any failure so that
 * pi keeps the previously published list and reports the refresh error.
 */
async function fetchCatalog(signal: AbortSignal): Promise<Model<"openai-completions">[]> {
	// Discovery bypasses pi's provider auth, so it must carry the gate
	// credential itself — harmless when the proxy gate is disabled (the
	// mlx-serve route strips client auth upstream anyway).
	const response = await fetch(CATALOG_URL, { signal, headers: { Authorization: `Bearer ${PROXY_TOKEN}` } });
	if (!response.ok) throw new Error(`mlx-serve catalog: HTTP ${response.status}`);
	const body = (await response.json()) as { data?: MlxServeCatalogEntry[] };
	const models: Model<"openai-completions">[] = [];
	for (const entry of body.data ?? []) {
		const model = toChatModel(entry);
		if (model) models.push(model);
	}
	const ready = (id: string): number => {
		const entry = (body.data ?? []).find((candidate) => candidate.id === id);
		return entry?.state === "ready" ? 0 : 1;
	};
	return models.sort((a, b) => ready(a.id) - ready(b.id) || a.id.localeCompare(b.id));
}

/** Async factory: pi waits for it, so the baseline catalog is ready for startup model selection. */
export default async function (pi: ExtensionAPI): Promise<void> {
	// openrouter: override ONLY the endpoint of pi's built-in provider. The
	// built-in catalog, compat flags and dialect handling are preserved —
	// never copy the model list here. The proxy replaces this Bearer value
	// with the real OpenRouter key (after checking it against its own
	// LLM_PROXY_TOKEN gate, when that gate is enabled).
	pi.registerProvider("openrouter", {
		baseUrl: `${BASE}/openrouter/v1`,
		apiKey: PROXY_TOKEN,
	});

	// Best-effort baseline for mlx-serve. Print mode never refreshes catalogs
	// and a fresh container has no persisted store yet, so without this pass
	// `pia ask` would see no models at all. A failure here is not fatal.
	let baseline: Model<"openai-completions">[] = [];
	try {
		baseline = await fetchCatalog(AbortSignal.timeout(STARTUP_FETCH_TIMEOUT_MS));
	} catch {
		// mlx-serve (or the proxy) down at startup: register with an empty
		// baseline; interactive refreshes fill the list once it is reachable.
	}

	pi.registerProvider(
		createProvider<"openai-completions">({
			id: PROVIDER_ID,
			name: "MLX Serve (llm-proxy)",
			baseUrl: BASE_URL,
			// The proxy owns upstream credentials; it validates this Bearer
			// against its LLM_PROXY_TOKEN gate (when set) and strips or
			// replaces auth before forwarding.
			auth: {
				apiKey: {
					name: "llm-proxy token",
					resolve: async () => ({ auth: { apiKey: PROXY_TOKEN } }),
				},
			},
			models: baseline,
			api: openAICompletionsApi(),
			fetchModels: (context: RefreshModelsContext) => fetchCatalog(context.signal),
		}),
	);
}
