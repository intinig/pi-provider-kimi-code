import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import type { ExtensionAPI, ToolDefinition } from "@earendil-works/pi-coding-agent";
import registerKimiCodeExtension from "../index.ts";

function tempDir(name: string): string {
  return mkdtempSync(join(tmpdir(), `${name}-`));
}

function withCwd<T>(cwd: string, fn: () => T): T {
  const originalCwd = process.cwd();
  process.chdir(cwd);
  try {
    return fn();
  } finally {
    process.chdir(originalCwd);
  }
}

function makePi() {
  const tools: ToolDefinition[] = [];
  const providers: string[] = [];
  const pi = {
    registerProvider(name: string) {
      providers.push(name);
    },
    registerTool(tool: ToolDefinition) {
      tools.push(tool);
    },
  } as unknown as ExtensionAPI;
  return { pi, providers, tools };
}

describe("extension tool registration", () => {
  it("does not register Moonshot tools when config is missing", () => {
    const cwd = tempDir("kimi-extension-cwd");
    const { pi, providers, tools } = makePi();

    withCwd(cwd, () => registerKimiCodeExtension(pi));

    assert.deepEqual(providers, ["kimi-coding"]);
    assert.deepEqual(
      tools.map((tool) => tool.name),
      [],
    );
  });

  it("registers only enabled Moonshot tools", () => {
    const cwd = tempDir("kimi-extension-cwd");
    const configPath = join(cwd, ".pi", "pi-provider-kimi-code.json");
    mkdirSync(join(configPath, ".."), { recursive: true });
    writeFileSync(
      configPath,
      JSON.stringify({
        tools: {
          moonshot_search: { enabled: true },
          moonshot_fetch: { enabled: false },
        },
      }),
      "utf8",
    );
    const { pi, tools } = makePi();

    withCwd(cwd, () => registerKimiCodeExtension(pi));

    assert.deepEqual(
      tools.map((tool) => tool.name),
      ["moonshot_search"],
    );
  });
});
