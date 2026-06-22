import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  pi.registerProvider("llama-cpp-local", {
    name: "llama-cpp",
    baseUrl: "http://petunia.home.lan:8000/v1",
    apiKey: "not-required",
    api: "openai",

    models: [
      {
        id: "qwen3.6-35b-a3b-coding-agent-mtp-128k",
        name: "Qwen 3.6 35B (128k)",
        contextWindow: 131072,
        maxTokens: 16384,
        input: ["text"],
        reasoning: true,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        compat: { supportsDeveloperRole: false, supportsReasoningEffort: false },
      },
    ],
  });
}
