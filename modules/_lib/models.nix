{ pkgs, lib }:

# The self-hosted inference fleet, in one place.
#
# Two harnesses need this catalogue in two different shapes: pi reads a
# models.json of its own design, dsh reads an `llm-pi-ai` provider profile in
# YAML. Both ultimately drive the same library (@earendil-works/pi-ai) against
# the same endpoint, so describing the models twice invites the two copies to
# drift on a model add. Describe them once here and render per consumer.

let
  # vLLM's OpenAI-compatible surface. Not the bare host: pi's `baseUrl` and
  # dsh's `baseURL` are both the API root, /v1 included.
  baseUrl = "http://petunia.home.lan:8000/v1";

  # Reasoning is on by default at `medium`. The endpoint's own default is
  # xhigh, which burns most of a 128k context on thinking before the model
  # reaches the task; medium is the level these models are actually useful at.
  defaultThinkingLevel = "medium";
  defaultModel = "Qwen3.8-MXFP4";

  # Token budget per thinking level.
  #
  # pi accepts all five. dsh's pi-ai adapter declares only four — see
  # `thinkingBudgets` in @deepseek-ai/dsh-llm-pi-ai, which is a closed schema of
  # { minimal, low, medium, high }. An xhigh key there fails config load, so
  # `dshThinkingBudgets` drops it. xhigh remains a selectable *level* in dsh
  # (ModelThinkingLevel carries it); it just has no configurable budget.
  thinkingBudgets = {
    minimal = 2048;
    low = 8192;
    medium = 24576;
    high = 65536;
    xhigh = 131072;
  };
  dshThinkingBudgets = lib.filterAttrs (name: _: name != "xhigh") thinkingBudgets;

  # Sampling, as the model card specifies it for thinking mode. Every model the
  # endpoint serves is a Qwen3 reasoning model, so this is one attrset rather
  # than a per-model field, for the same reason `reasoning` below is not one.
  #
  # These are not decoration: vLLM declares and validates all six (an
  # out-of-range value is a 400 naming the parameter), and without them the
  # request inherits whatever default the endpoint was launched with.
  #
  # If a non-Qwen model ever joins the list, move this to a per-entry field.
  samplingParams = {
    temperature = 1.0;
    top_p = 0.95;
    top_k = 20;
    min_p = 0.0;
    presence_penalty = 0.0;
    repetition_penalty = 1.0;
  };

  # Every model the endpoint serves. `id` is the wire name vLLM was started
  # with; adding one here reaches both harnesses.
  #
  # Order is presentation, not preference — it is the order each harness lists
  # models in its picker. `defaultModel` above is what actually gets selected,
  # so a model can be reordered here without changing what runs.
  models = [
    {
      id = "Qwen3.8-MXFP4";
      name = "Qwen 3.8 27B (256k)";
      contextWindow = 262144;
    }
    {
      id = "qwen3.6-35b-a3b";
      name = "Qwen 3.6 35B-A3B (128k)";
      contextWindow = 131072;
    }
  ];

  # Every model here is a reasoning, multi-modal model, so neither is a
  # per-model field above. Cost is zero because the endpoint is ours; pi still
  # wants the key present or it renders the model as unpriced rather than free.
  piModel = model: {
    inherit (model) id name contextWindow;
    reasoning = true;
    inherit samplingParams;
    cost = {
      input = 0;
      output = 0;
      cacheRead = 0;
      cacheWrite = 0;
    };
  };
in

{
  inherit
    baseUrl
    defaultThinkingLevel
    defaultModel
    thinkingBudgets
    dshThinkingBudgets
    samplingParams
    models
    ;

  # ~/.pi/agent/models.json, as consumed by pi.
  piModelsJson = (pkgs.formats.json { }).generate "pi-models.json" {
    inherit defaultThinkingLevel thinkingBudgets;
    providers.vllm-local = {
      name = "vllm";
      inherit baseUrl;
      apiKey = "not-required";
      api = "openai-completions";
      models = map piModel models;
    };
  };
}
