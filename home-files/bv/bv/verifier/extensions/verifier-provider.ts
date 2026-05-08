import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  pi.registerProvider("llama-cpp-local", {
    name: "llama-cpp",
    baseUrl: "http://dualie.home.lan:8001/v1",
    apiKey: "not-required",
    api: "openai-completions",

    compat: {
      supportsDeveloperRole: false,
      supportsReasoningEffort: false,
    },

    models: [
      {
        id: "qwen3.6-35b-a3b-coding-agent-64k",
        name: "Qwen 3.6 35B Verifier (64k)",
        contextWindow: 65536,
        input: ["text"],
        reasoning: false,
      },
      {
        id: "qwen3.6-verifier-128k",
        name: "Qwen 3.6 35B Verifier (128k)",
        contextWindow: 131072,
        input: ["text"],
        reasoning: false,
      },
    ],
  });
}
