import { describe, it } from "node:test";
import assert from "node:assert/strict";

import { buildMoonshotSearchTool } from "../src/tools/moonshot.ts";

describe("moonshot_search", () => {
  it("posts the expected URL, headers, and body, then maps search results", async () => {
    const calls: Array<{ url: string; init: RequestInit }> = [];
    const mockFetch: typeof fetch = async (input, init) => {
      calls.push({ url: String(input), init: init ?? {} });
      return new Response(
        JSON.stringify({
          search_results: [
            {
              title: "Example",
              url: "https://example.com",
              snippet: "Example summary",
              content: "Full page",
              ignored: "ignored",
            },
          ],
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      );
    };
    const tool = buildMoonshotSearchTool({
      deps: { fetch: mockFetch, getAccessToken: () => "oauth-token" },
    });

    const result = await tool.execute(
      "tool-call-1",
      { query: "kimi code", limit: 99, include_content: true },
      undefined,
      undefined,
      undefined as never,
    );

    assert.equal(calls.length, 1);
    assert.equal(calls[0].url, "https://api.kimi.com/coding/v1/search");
    assert.equal(calls[0].init.method, "POST");
    assert.equal(
      (calls[0].init.headers as Record<string, string>).Authorization,
      "Bearer oauth-token",
    );
    assert.equal(
      (calls[0].init.headers as Record<string, string>)["X-Msh-Tool-Call-Id"],
      "tool-call-1",
    );
    assert.deepEqual(JSON.parse(calls[0].init.body as string), {
      text_query: "kimi code",
      limit: 20,
      enable_page_crawling: true,
      timeout_seconds: 30,
    });
    assert.deepEqual(result.details, [
      {
        title: "Example",
        url: "https://example.com",
        snippet: "Example summary",
        content: "Full page",
      },
    ]);
  });

  it("returns an error result when OAuth credentials are missing", async () => {
    const tool = buildMoonshotSearchTool({
      deps: {
        fetch: (() => {
          throw new Error("fetch should not be called");
        }) as typeof fetch,
        getAccessToken: () => null,
      },
    });

    const result = await tool.execute(
      "tool-call-1",
      { query: "kimi code" },
      undefined,
      undefined,
      undefined as never,
    );

    assert.match(
      result.content[0].type === "text" ? result.content[0].text : "",
      /\/login kimi-coding/,
    );
  });
});
