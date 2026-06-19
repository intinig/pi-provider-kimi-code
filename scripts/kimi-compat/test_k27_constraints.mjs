// Test K2.7 Code API constraints discovered from official docs:
//   1. temperature / top_p must be default (1.0 / 0.95), other values → error
//   2. tool_choice only accepts "auto" or "none", other values → error
//   3. Multi-turn tool call: assistant message must retain reasoning_content
//
// Usage: KIMI_API_KEY=sk-... node scripts/kimi-compat/test_k27_constraints.mjs

import https from "node:https";

const apiKey = process.env.KIMI_API_KEY ?? process.argv[2];
const baseUrl = process.env.KIMI_CODE_BASE_URL ?? "https://api.kimi.com/coding/v1";

if (!apiKey) {
  console.error("Usage: KIMI_API_KEY=sk-... node scripts/kimi-compat/test_k27_constraints.mjs");
  process.exit(1);
}

const url = new URL("chat/completions", baseUrl.replace(/\/?$/, "/"));

function send(label, payload) {
  const body = JSON.stringify(payload);
  return new Promise((resolve, reject) => {
    const req = https.request(
      {
        protocol: url.protocol,
        hostname: url.hostname,
        port: url.port || 443,
        path: `${url.pathname}${url.search}`,
        method: "POST",
        headers: {
          Authorization: `Bearer ${apiKey}`,
          "Content-Type": "application/json",
          "Content-Length": String(Buffer.byteLength(body)),
          "User-Agent": "KimiCLI/1.44.0",
          "X-Msh-Platform": "kimi_cli",
          "X-Msh-Version": "1.44.0",
        },
      },
      (res) => {
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => {
          const raw = Buffer.concat(chunks).toString("utf8");
          let detail = "";
          let parsed = null;
          try {
            parsed = JSON.parse(raw);
            if (parsed.error) detail = ` — ${parsed.error.message ?? JSON.stringify(parsed.error)}`;
          } catch {}
          const ok = res.statusCode < 400;
          console.log(`  [${label}] ${res.statusCode} ${ok ? "OK" : "REJECT"}${detail}`);
          resolve({ ok, status: res.statusCode, body: parsed });
        });
      },
    );
    req.on("error", reject);
    req.end(body);
  });
}

const BASE = {
  model: "kimi-for-coding",
  messages: [{ role: "user", content: "Say hi." }],
  max_completion_tokens: 32,
  stream: false,
  thinking: { type: "enabled" },
};

const TOOL = {
  type: "function",
  function: {
    name: "get_weather",
    description: "Get weather for a city",
    parameters: {
      type: "object",
      properties: { city: { type: "string" } },
      required: ["city"],
    },
  },
};

// ─── Group A: temperature / top_p constraints ───

console.log("=== A: temperature / top_p constraints ===");

await send("A1-default-no-temp", { ...BASE });
await send("A2-temp-1.0", { ...BASE, temperature: 1.0 });
await send("A3-temp-0.7", { ...BASE, temperature: 0.7 });
await send("A4-temp-0", { ...BASE, temperature: 0 });
await send("A5-top_p-0.95", { ...BASE, top_p: 0.95 });
await send("A6-top_p-0.8", { ...BASE, top_p: 0.8 });
await send("A7-top_p-1.0", { ...BASE, top_p: 1.0 });

// ─── Group B: tool_choice constraints ───

console.log("\n=== B: tool_choice constraints ===");

const WITH_TOOL = { ...BASE, tools: [TOOL] };

await send("B1-no-tool_choice", { ...WITH_TOOL });
await send("B2-tool_choice-auto", { ...WITH_TOOL, tool_choice: "auto" });
await send("B3-tool_choice-none", { ...WITH_TOOL, tool_choice: "none" });
await send("B4-tool_choice-required", { ...WITH_TOOL, tool_choice: "required" });
await send("B5-tool_choice-function", {
  ...WITH_TOOL,
  tool_choice: { type: "function", function: { name: "get_weather" } },
});

// ─── Group C: reasoning_content round-trip ───

console.log("\n=== C: reasoning_content in multi-turn tool call ===");

// Step 1: get a tool call response with reasoning_content
const toolCallPrompt = {
  model: "kimi-for-coding",
  messages: [{ role: "user", content: "What is the weather in Tokyo?" }],
  tools: [TOOL],
  tool_choice: "auto",
  max_completion_tokens: 128,
  stream: false,
  thinking: { type: "enabled" },
};

const step1 = await send("C1-trigger-tool-call", toolCallPrompt);

if (step1.ok && step1.body?.choices?.[0]?.message?.tool_calls?.length > 0) {
  const assistantMsg = step1.body.choices[0].message;
  const toolCallId = assistantMsg.tool_calls[0].id;
  const reasoningContent = assistantMsg.reasoning_content ?? null;

  console.log(
    `  (reasoning_content present: ${reasoningContent !== null}, length: ${reasoningContent?.length ?? 0})`,
  );

  // C2: with reasoning_content preserved
  const withReasoning = {
    model: "kimi-for-coding",
    messages: [
      { role: "user", content: "What is the weather in Tokyo?" },
      {
        role: "assistant",
        content: assistantMsg.content ?? "",
        reasoning_content: reasoningContent ?? "",
        tool_calls: assistantMsg.tool_calls,
      },
      {
        role: "tool",
        tool_call_id: toolCallId,
        content: JSON.stringify({ city: "Tokyo", temp: "22C", condition: "sunny" }),
      },
    ],
    tools: [TOOL],
    max_completion_tokens: 64,
    stream: false,
    thinking: { type: "enabled" },
  };
  await send("C2-with-reasoning_content", withReasoning);

  // C3: without reasoning_content (should this fail?)
  const withoutReasoning = {
    ...withReasoning,
    messages: [
      { role: "user", content: "What is the weather in Tokyo?" },
      {
        role: "assistant",
        content: assistantMsg.content ?? "",
        tool_calls: assistantMsg.tool_calls,
      },
      {
        role: "tool",
        tool_call_id: toolCallId,
        content: JSON.stringify({ city: "Tokyo", temp: "22C", condition: "sunny" }),
      },
    ],
  };
  await send("C3-without-reasoning_content", withoutReasoning);

  // C4: with empty string reasoning_content
  const withEmptyReasoning = {
    ...withReasoning,
    messages: [
      { role: "user", content: "What is the weather in Tokyo?" },
      {
        role: "assistant",
        content: assistantMsg.content ?? "",
        reasoning_content: "",
        tool_calls: assistantMsg.tool_calls,
      },
      {
        role: "tool",
        tool_call_id: toolCallId,
        content: JSON.stringify({ city: "Tokyo", temp: "22C", condition: "sunny" }),
      },
    ],
  };
  await send("C4-empty-reasoning_content", withEmptyReasoning);
} else {
  console.log("  (skipped C2-C4: step 1 did not produce a tool call)");
}

console.log("\nDone.");
