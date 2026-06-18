import { readFileSync } from "node:fs";
import { join } from "node:path";
import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { optimizeToolSchemas, resetToolSchemaCache } from "../src/schema-dedup.ts";

function jsonSize(v: unknown): number {
  return Buffer.byteLength(JSON.stringify(v));
}

function loadCapturedTools(): unknown[] {
  const capturePath = join(
    import.meta.dirname,
    "..",
    "fixtures",
    "pi-subagents-kimi-schema-repro",
    "captures",
    "0001-2026-06-04T23-22-09-516Z-request.json",
  );
  const capture = JSON.parse(readFileSync(capturePath, "utf8"));
  const body = JSON.parse(capture.bodyUtf8);
  return body.tools;
}

describe("optimizeToolSchemas", () => {
  it("reduces oversized subagent schema below 15 KB", () => {
    resetToolSchemaCache();
    const tools = loadCapturedTools();
    const subagent = tools[4] as Record<string, unknown>;
    const fn = subagent.function as Record<string, unknown>;
    const originalSize = jsonSize(fn.parameters);
    assert.ok(originalSize > 15_000, `original should be oversized: ${originalSize}`);

    const optimized = optimizeToolSchemas(tools);
    const optFn = (optimized[4] as Record<string, unknown>).function as Record<string, unknown>;
    const optimizedSize = jsonSize(optFn.parameters);
    assert.ok(optimizedSize < 15_000, `optimized should be under 15KB: ${optimizedSize}`);
  });

  it("does not modify tools under the threshold", () => {
    resetToolSchemaCache();
    const tools = loadCapturedTools();
    const optimized = optimizeToolSchemas(tools);

    for (let i = 0; i < 4; i++) {
      const orig = (tools[i] as Record<string, unknown>).function as Record<string, unknown>;
      const opt = (optimized[i] as Record<string, unknown>).function as Record<string, unknown>;
      assert.deepStrictEqual(opt.parameters, orig.parameters, `tool ${i} should be unchanged`);
    }
  });

  it("produces valid JSON Schema with $defs and $ref", () => {
    resetToolSchemaCache();
    const tools = loadCapturedTools();
    const optimized = optimizeToolSchemas(tools);
    const optFn = (optimized[4] as Record<string, unknown>).function as Record<string, unknown>;
    const params = optFn.parameters as Record<string, unknown>;

    assert.ok(params.$defs, "should have $defs");
    const defs = params.$defs as Record<string, unknown>;
    assert.ok(Object.keys(defs).length > 0, "should have at least one $def entry");

    const serialized = JSON.stringify(params);
    assert.ok(serialized.includes('"$ref"'), "should contain $ref references");
    for (const key of Object.keys(defs)) {
      assert.ok(serialized.includes(`"#/$defs/${key}"`), `$ref should reference $defs/${key}`);
    }
  });

  it("is deterministic — same input produces identical output", () => {
    resetToolSchemaCache();
    const tools = loadCapturedTools();
    const result1 = optimizeToolSchemas(tools);

    resetToolSchemaCache();
    const result2 = optimizeToolSchemas(loadCapturedTools());

    assert.deepStrictEqual(result1, result2);
  });

  it("caches result based on tool fingerprint", () => {
    resetToolSchemaCache();
    const tools = loadCapturedTools();
    const result1 = optimizeToolSchemas(tools);
    const result2 = optimizeToolSchemas(tools);
    assert.strictEqual(result1, result2, "should return same reference on cache hit");
  });

  it("invalidates cache when tool names change", () => {
    resetToolSchemaCache();
    const tools = loadCapturedTools();
    const result1 = optimizeToolSchemas(tools);
    const result2 = optimizeToolSchemas(tools.slice(0, 4));
    assert.notStrictEqual(result1, result2, "different tool set should bust cache");
  });

  it("handles tools without function.parameters gracefully", () => {
    resetToolSchemaCache();
    const tools = [{ type: "function", function: { name: "bare", description: "no params" } }];
    const result = optimizeToolSchemas(tools);
    assert.deepStrictEqual(result, tools);
  });

  it("returns original array when no tools exceed threshold", () => {
    resetToolSchemaCache();
    const smallTools = [
      {
        type: "function",
        function: {
          name: "small",
          description: "test",
          parameters: { type: "object", properties: { a: { type: "string" } } },
        },
      },
    ];
    const result = optimizeToolSchemas(smallTools);
    assert.strictEqual(result, smallTools, "should return same reference when nothing to optimize");
  });

  it("merges with existing $defs without collision", () => {
    resetToolSchemaCache();
    const repeated = {
      type: "object",
      properties: {
        name: { type: "string" },
        value: { type: "integer" },
        extra: { type: "string", description: "x".repeat(200) },
      },
    };
    const schema = {
      type: "object",
      $defs: {
        existing: { type: "string", description: "pre-existing def" },
      },
      properties: {} as Record<string, unknown>,
    };
    for (let i = 0; i < 200; i++) {
      schema.properties[`p${i}`] = JSON.parse(JSON.stringify(repeated));
    }

    const tools = [
      {
        type: "function",
        function: { name: "test", description: "test", parameters: schema },
      },
    ];

    const result = optimizeToolSchemas(tools);
    const params = ((result[0] as Record<string, unknown>).function as Record<string, unknown>)
      .parameters as Record<string, unknown>;
    const defs = params.$defs as Record<string, unknown>;

    assert.ok(defs.existing, "pre-existing $defs entry should be preserved");
    assert.ok(Object.keys(defs).length > 1, "should have added new $defs entries");
  });
});
