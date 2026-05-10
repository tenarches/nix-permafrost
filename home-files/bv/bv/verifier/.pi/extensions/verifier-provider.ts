import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  pi.registerProvider("llama-cpp-local", {
    name: "llama-cpp",
    baseUrl: "http://dualie.home.lan:8001/v1",
    apiKey: "not-required",
    api: "openai-completions",

    models: [
      {
        id: "qwen3.6-35b-a3b-coding-agent-64k",
        name: "Qwen 3.6 35B Verifier (64k)",
        contextWindow: 65536,
        maxTokens: 16384,
        input: ["text"],
        reasoning: false,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        compat: { supportsDeveloperRole: false, supportsReasoningEffort: false },
      },
      {
        id: "qwen3.6-verifier-128k",
        name: "Qwen 3.6 35B Verifier (128k)",
        contextWindow: 131072,
        maxTokens: 16384,
        input: ["text"],
        reasoning: false,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        compat: { supportsDeveloperRole: false, supportsReasoningEffort: false },
      },
    ],
  });
}
