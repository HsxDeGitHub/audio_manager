import { join } from "node:path";
import {
  createAgentSession,
  createExtensionRuntime,
  ModelRuntime,
  SessionManager,
  SettingsManager,
} from "@earendil-works/pi-coding-agent";
import {
  createAssistantMessageEventStream,
} from "@earendil-works/pi-ai";
import { streamSimple } from "@earendil-works/pi-ai/compat";

const workspace = process.argv[2];
if (!workspace) throw new Error("An isolated workspace is required");
const callbacks = new Map();
const controllers = new Map();
let sequence = 0;

function send(record) {
  process.stdout.write(`${JSON.stringify(record)}\n`);
}

function remote(owner, method, payload, signal) {
  return new Promise((resolve, reject) => {
    const id = `callback-${++sequence}`;
    const abort = () => {
      callbacks.delete(id);
      reject(new Error("Host operation aborted"));
    };
    if (signal?.aborted) return abort();
    signal?.addEventListener("abort", abort, { once: true });
    callbacks.set(id, {
      resolve(value) {
        signal?.removeEventListener("abort", abort);
        resolve(value);
      },
      reject(error) {
        signal?.removeEventListener("abort", abort);
        reject(error);
      },
    });
    send({ type: "callback", owner, id, method, payload });
  });
}

function modelDefinition(configuration) {
  return {
    id: configuration.model ?? "host",
    name: configuration.model ?? "host",
    provider: "tingyue",
    api: "openai-completions",
    baseUrl: configuration.baseURL ?? "http://127.0.0.1:1/v1",
    reasoning: false,
    input: ["text"],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow: 262144,
    maxTokens: configuration.maxOutputTokens ?? 8192,
    compat: { supportsDeveloperRole: false, supportsStore: false, maxTokensField: "max_tokens" },
  };
}

function safeProviderError(message, status) {
  const text = message ?? "";
  const code = (status >= 400 ? status : undefined) ?? Number(text.match(/\b(400|401|403|404|408|413|422|429|500|502|503|504)\b/)?.[1]);
  let reason = "invalid_response";
  if (/timeout|timed out/i.test(text)) reason = "timeout";
  else if (/connection|fetch failed|socket|ECONN|network|terminated/i.test(text)) reason = "connection";
  return { reason, status: code || null };
}

async function compatibleFetch(id, input, options) {
  const response = await fetch(input, options);
  if (response.ok || typeof options?.body !== "string") return response;
  const detail = await response.clone().json().catch(() => ({}));
  const error = detail.error ?? detail;
  const unsupported = response.status === 501 || (error.param === "stream" &&
    ["unsupported_value", "unsupported_parameter", "not_supported"].includes(error.code));
  if (!unsupported) return response;
  const payload = JSON.parse(options.body);
  if (!payload.stream) return response;
  payload.stream = false;
  delete payload.stream_options;
  send({ type: "event", id, event: { type: "generation_mode" } });
  const fallback = await fetch(input, { ...options, body: JSON.stringify(payload) });
  if (!fallback.ok) return fallback;
  const completion = await fallback.json();
  const chunk = {
    ...completion,
    object: "chat.completion.chunk",
    choices: completion.choices.map((choice) => ({
      index: choice.index,
      finish_reason: choice.finish_reason,
      delta: {
        ...choice.message,
        ...(choice.message.tool_calls ? { tool_calls: choice.message.tool_calls.map((call, index) => ({
          ...call, index,
        })) } : {}),
      },
    })),
  };
  return new Response(`data: ${JSON.stringify(chunk)}\n\ndata: [DONE]\n\n`, {
    headers: { "Content-Type": "text/event-stream" },
  });
}

async function complete(id, payload) {
  const model = modelDefinition(payload.configuration);
  let status;
  const controller = new AbortController();
  controllers.set(id, controller);
  try {
    const options = {
      apiKey: payload.configuration.apiKey || "local-no-key",
      maxTokens: model.maxTokens,
      maxRetries: 0,
      timeoutMs: 180000,
      signal: controller.signal,
      async fetch(input, options) {
        const response = await compatibleFetch(id, input, options);
        status = response.status;
        return response;
      },
    };
    if (payload.toolChoice) {
      options.toolChoice = { type: "function", function: { name: payload.toolChoice } };
    }
    const stream = streamSimple(model, payload.context, options);
    for await (const event of stream) {
      if (event.type === "text_delta") {
        send({ type: "event", id, event: { type: "text_delta", delta: event.delta } });
      }
    }
    const response = await stream.result();
    if (["error", "aborted"].includes(response.stopReason)) {
      send({ id, method: "complete", error: safeProviderError(response.errorMessage, status) });
    } else {
      send({ id, result: response });
    }
  } catch (error) {
    send({ id, method: "complete", error: safeProviderError(error.message, error.status ?? status) });
  } finally {
    controllers.delete(id);
  }
}

async function agent(id, payload) {
  const settingsManager = SettingsManager.inMemory({
    retry: { enabled: false },
    compaction: { enabled: false },
    cacheWarming: "off",
  });
  const resourceLoader = {
    getExtensions: () => ({ extensions: [], errors: [], runtime: createExtensionRuntime() }),
    getSkills: () => ({ skills: [], diagnostics: [] }),
    getPrompts: () => ({ prompts: [], diagnostics: [] }),
    getThemes: () => ({ themes: [], diagnostics: [] }),
    getAgentsFiles: () => ({ agentsFiles: [] }),
    getSystemPrompt: () => payload.systemPrompt,
    getSystemPromptSource: () => undefined,
    getAppendSystemPrompt: () => [],
    getAppendSystemPromptSources: () => [],
    extendResources() {},
    async reload() {},
  };
  const modelRuntime = await ModelRuntime.create({
    authPath: join(workspace, "auth.json"),
    modelsPath: null,
    modelsStorePath: join(workspace, "models-cache.json"),
    refreshOnCreate: false,
    allowModelNetwork: false,
  });
  modelRuntime.registerProvider("tingyue", {
    api: "openai-completions",
    baseUrl: "http://127.0.0.1:1/v1",
    models: [modelDefinition({})],
  });
  await modelRuntime.setRuntimeApiKey("tingyue", "host-bridge");
  let session;
  let failure;
  async function invoke(method, data, signal) {
    try {
      return await remote(id, method, data, signal);
    } catch (error) {
      failure = error;
      session?.agent.abort();
      throw error;
    }
  }
  const customTools = payload.tools.map((tool) => ({
    ...tool,
    label: tool.name,
    async execute(toolCallId, arguments_, signal) {
      const result = await invoke("tool", { id: toolCallId, name: tool.name, arguments: arguments_ }, signal);
      return { content: [{ type: "text", text: result.text }], details: {} };
    },
  }));
  try {
    ({ session } = await createAgentSession({
      cwd: workspace,
      agentDir: workspace,
      model: modelDefinition({}),
      modelRuntime,
      thinkingLevel: "off",
      noTools: "builtin",
      tools: customTools.map((tool) => tool.name),
      customTools,
      resourceLoader,
      settingsManager,
      sessionManager: SessionManager.inMemory(workspace),
    }));
    session.agent.toolExecution = "sequential";
    // Source validation and idempotent receipts belong to the host's model-step boundary.
    session.agent.streamFunction = (_model, context, options) => {
      const stream = createAssistantMessageEventStream();
      void (async () => {
        try {
          const response = await invoke("model", {
            systemPrompt: payload.systemPrompt,
            messages: context.messages.filter((message) => message.role !== "system"),
          }, options?.signal);
          stream.push({ type: "done", reason: response.stopReason, message: response });
        } catch {
          stream.end({ role: "assistant", content: [], api: "openai-completions", provider: "tingyue",
            model: "host", stopReason: "aborted", timestamp: Date.now(), errorMessage: "Host step failed" });
        }
      })();
      return stream;
    };
    const unsubscribe = session.subscribe((event) => {
      if (event.type === "tool_execution_end" && event.isError && !failure) {
        failure = new Error("Tool validation failed");
        session.agent.abort();
      }
    });
    await session.prompt(payload.prompt);
    unsubscribe();
    if (failure) throw failure;
    const messages = session.messages;
    const last = messages.findLast((message) => message.role === "assistant");
    if (!last || last.stopReason === "aborted") throw new Error("No validated answer");
    send({ id, result: { response: last, systemPrompt: payload.systemPrompt,
      messages: messages.filter((message) => message.role !== "system") } });
  } catch {
    send({ id, error: { reason: "agent_failed" } });
  } finally {
    session?.dispose();
  }
}

let buffer = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  buffer += chunk;
  if (Buffer.byteLength(buffer) > 8 * 1024 * 1024) process.exit(1);
  let end;
  while ((end = buffer.indexOf("\n")) !== -1) {
    const line = buffer.slice(0, end);
    buffer = buffer.slice(end + 1);
    try {
      const record = JSON.parse(line);
      if (record.type === "callback_result") {
        const pending = callbacks.get(record.id);
        callbacks.delete(record.id);
        if (record.error) pending?.reject(new Error("Host step failed"));
        else pending?.resolve(record.result);
      } else if (record.type === "cancel") {
        controllers.get(record.id)?.abort();
      } else if (record.method === "complete") {
        void complete(record.id, record.payload);
      } else if (record.method === "agent") {
        void agent(record.id, record.payload).catch(() => send({ id: record.id, error: { reason: "startup_failed" } }));
      }
    } catch {
      process.exitCode = 1;
      process.stdin.destroy();
    }
  }
});
process.stdin.on("end", () => {
  for (const controller of controllers.values()) controller.abort();
  for (const pending of callbacks.values()) pending.reject(new Error("Host disconnected"));
  callbacks.clear();
});
