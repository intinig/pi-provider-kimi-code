import { describe, it } from "node:test";
import assert from "node:assert/strict";

import { visibleWidth } from "@earendil-works/pi-tui";

import { buildKimiDatasourceTool } from "../src/tools/datasource.ts";

function renderText(component: { render: (width: number) => string[] }): string {
  return component.render(80).join("\n");
}

describe("kimi_datasource datasource", () => {
  it("calls get_data_source_desc when api_name is omitted", async () => {
    const calls: Array<{ url: string; init: RequestInit }> = [];
    const mockFetch: typeof fetch = async (input, init) => {
      calls.push({ url: String(input), init: init ?? {} });
      return new Response(
        JSON.stringify({
          is_success: true,
          result: {
            assistant: [{ text: "Available APIs: search, detail" }],
          },
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      );
    };

    const tool = buildKimiDatasourceTool({
      deps: { fetch: mockFetch, getAccessToken: () => "oauth-token" },
    });

    const result = await tool.execute(
      "tool-call-1",
      { data_source_name: "arxiv" },
      undefined,
      undefined,
      undefined as never,
    );

    assert.equal(calls.length, 1);
    assert.equal(calls[0].url, "https://api.kimi.com/coding/v1/tools");
    assert.deepEqual(JSON.parse(calls[0].init.body as string), {
      method: "get_data_source_desc",
      params: { name: "arxiv" },
    });
    assert.equal(
      result.content[0].type === "text" ? result.content[0].text : "",
      "Available APIs: search, detail",
    );
  });

  it("calls call_data_source_tool when api_name is provided", async () => {
    const calls: Array<{ url: string; init: RequestInit }> = [];
    const mockFetch: typeof fetch = async (input, init) => {
      calls.push({ url: String(input), init: init ?? {} });
      return new Response(
        JSON.stringify({
          is_success: true,
          result: {
            user: [{ text: "Paper found: Attention Is All You Need" }],
          },
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      );
    };

    const tool = buildKimiDatasourceTool({
      deps: { fetch: mockFetch, getAccessToken: () => "oauth-token" },
    });

    const result = await tool.execute(
      "tool-call-1",
      { data_source_name: "arxiv", api_name: "search", params: { query: "transformer" } },
      undefined,
      undefined,
      undefined as never,
    );

    assert.equal(calls.length, 1);
    assert.deepEqual(JSON.parse(calls[0].init.body as string), {
      method: "call_data_source_tool",
      params: {
        data_source_name: "arxiv",
        api_name: "search",
        params: { query: "transformer" },
      },
    });
    assert.equal(
      result.content[0].type === "text" ? result.content[0].text : "",
      "Paper found: Attention Is All You Need",
    );
  });

  it("returns an error when OAuth credentials are missing", async () => {
    const tool = buildKimiDatasourceTool({
      deps: {
        fetch: (() => {
          throw new Error("should not call");
        }) as typeof fetch,
        getAccessToken: () => null,
      },
    });

    const result = await tool.execute(
      "tool-call-1",
      { data_source_name: "arxiv", api_name: "search" },
      undefined,
      undefined,
      undefined as never,
    );

    assert.match(
      result.content[0].type === "text" ? result.content[0].text : "",
      /\/login kimi-coding/,
    );
  });

  it("returns an error for non-2xx response", async () => {
    const mockFetch: typeof fetch = async () => new Response("server error", { status: 500 });

    const tool = buildKimiDatasourceTool({
      deps: { fetch: mockFetch, getAccessToken: () => "oauth-token" },
    });

    const result = await tool.execute(
      "tool-call-1",
      { data_source_name: "arxiv" },
      undefined,
      undefined,
      undefined as never,
    );

    assert.match(result.content[0].type === "text" ? result.content[0].text : "", /500/);
  });

  it("returns an error when is_success is false", async () => {
    const mockFetch: typeof fetch = async () =>
      new Response(JSON.stringify({ is_success: false, error: "invalid api" }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });

    const tool = buildKimiDatasourceTool({
      deps: { fetch: mockFetch, getAccessToken: () => "oauth-token" },
    });

    const result = await tool.execute(
      "tool-call-1",
      { data_source_name: "arxiv" },
      undefined,
      undefined,
      undefined as never,
    );

    assert.match(result.content[0].type === "text" ? result.content[0].text : "", /invalid api/);
  });

  it("refreshes OAuth credentials once on 401 and retries", async () => {
    const calls: Array<{ url: string; init: RequestInit }> = [];
    const mockFetch: typeof fetch = async (input, init) => {
      calls.push({ url: String(input), init: init ?? {} });
      if (calls.length === 1) return new Response("unauthorized", { status: 401 });
      return new Response(JSON.stringify({ is_success: true, result: { assistant: ["ok"] } }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    };
    const refreshes: string[] = [];

    const tool = buildKimiDatasourceTool({
      deps: {
        fetch: mockFetch,
        getAccessToken: () => "stale-token",
        refreshAccessToken: async (token) => {
          refreshes.push(token);
          return "fresh-token";
        },
      },
    });

    const result = await tool.execute(
      "tool-call-1",
      { data_source_name: "arxiv" },
      undefined,
      undefined,
      undefined as never,
    );

    assert.equal(calls.length, 2);
    assert.deepEqual(refreshes, ["stale-token"]);
    assert.equal(
      (calls[0].init.headers as Record<string, string>).Authorization,
      "Bearer stale-token",
    );
    assert.equal(
      (calls[1].init.headers as Record<string, string>).Authorization,
      "Bearer fresh-token",
    );
    assert.equal(result.content[0].type === "text" ? result.content[0].text : "", "ok");
  });

  it("uses KIMI_DATASOURCE_API_URL when provided", async () => {
    const original = process.env.KIMI_DATASOURCE_API_URL;
    const calls: Array<{ url: string; init: RequestInit }> = [];
    const mockFetch: typeof fetch = async (input, init) => {
      calls.push({ url: String(input), init: init ?? {} });
      return new Response(JSON.stringify({ is_success: true, result: { assistant: ["ok"] } }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    };

    try {
      process.env.KIMI_DATASOURCE_API_URL = "https://proxy.example.com/tools";
      const tool = buildKimiDatasourceTool({
        deps: { fetch: mockFetch, getAccessToken: () => "oauth-token" },
      });

      await tool.execute(
        "tool-call-1",
        { data_source_name: "arxiv" },
        undefined,
        undefined,
        undefined as never,
      );
    } finally {
      if (original === undefined) delete process.env.KIMI_DATASOURCE_API_URL;
      else process.env.KIMI_DATASOURCE_API_URL = original;
    }

    assert.equal(calls[0].url, "https://proxy.example.com/tools");
  });

  it("renders datasource result collapsed by default", () => {
    const tool = buildKimiDatasourceTool({ defaultCollapsed: true });
    const component = tool.renderResult!(
      { content: [{ type: "text", text: "x".repeat(300) }], details: "x".repeat(300) },
      { expanded: false, isPartial: false },
      undefined as never,
      undefined as never,
    );

    assert.match(renderText(component), /kimi_datasource:/);
    assert.doesNotMatch(renderText(component), /x{250}/);
  });

  it("truncates long world_bank datasource docs preview to the render width", () => {
    const tool = buildKimiDatasourceTool({ defaultCollapsed: true });
    const component = tool.renderResult!(
      {
        content: [{ type: "text", text: `\"# world_bank_open_data\\n${"x".repeat(300)}` }],
        details: "",
      },
      { expanded: false, isPartial: false },
      undefined as never,
      undefined as never,
    );

    const lines = component.render(40);
    assert.ok(lines.every((line) => visibleWidth(line) <= 40));
  });

  it("renders datasource result expanded when configured", () => {
    const tool = buildKimiDatasourceTool({ defaultCollapsed: false });
    const component = tool.renderResult!(
      {
        content: [{ type: "text", text: "full datasource output" }],
        details: "full datasource output",
      },
      { expanded: false, isPartial: false },
      undefined as never,
      undefined as never,
    );

    assert.equal(renderText(component), "full datasource output");
  });
});
