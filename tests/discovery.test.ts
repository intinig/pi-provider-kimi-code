import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { discoverKimiModelMetadata } from "../index.ts";

type FetchCall = { url: string; init?: RequestInit };

function mockFetch(responder: (call: FetchCall) => Response | Promise<Response>) {
  const original = globalThis.fetch;
  const calls: FetchCall[] = [];
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = input instanceof Request ? input.url : String(input);
    const call: FetchCall = { url, init };
    calls.push(call);
    return responder(call);
  }) as typeof fetch;
  return {
    calls,
    restore() {
      globalThis.fetch = original;
    },
  };
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

let mock: ReturnType<typeof mockFetch> | undefined;

afterEach(() => {
  mock?.restore();
  mock = undefined;
});

beforeEach(() => {
  delete process.env.KIMI_CODE_BASE_URL;
});

describe("discoverKimiModelMetadata", () => {
  it("returns empty when accessToken is missing", async () => {
    mock = mockFetch(() => jsonResponse({}));
    const result = await discoverKimiModelMetadata("");
    assert.deepEqual(result, {});
    assert.equal(mock.calls.length, 0);
  });

  it("hits /v1/models on the configured base URL with Bearer auth", async () => {
    mock = mockFetch(() =>
      jsonResponse({
        data: [{ id: "kimi-for-coding", display_name: "Kimi For Coding", context_length: 262144 }],
      }),
    );

    await discoverKimiModelMetadata("tok-1");

    assert.equal(mock.calls.length, 1);
    assert.equal(mock.calls[0]?.url, "https://api.kimi.com/coding/v1/models");
    const headers = mock.calls[0]?.init?.headers as Record<string, string>;
    assert.equal(headers.Authorization, "Bearer tok-1");
  });

  it("prefers the entry with id 'kimi-for-coding' even when other models are present", async () => {
    mock = mockFetch(() =>
      jsonResponse({
        data: [
          { id: "k2p7-beta", display_name: "Beta K2.7" },
          { id: "kimi-for-coding", display_name: "Kimi For Coding", context_length: 262144 },
        ],
      }),
    );

    const result = await discoverKimiModelMetadata("tok-1");
    assert.equal(result.wireModelId, "kimi-for-coding");
    assert.equal(result.modelDisplay, "Kimi For Coding");
    assert.equal(result.contextLength, 262144);
  });

  it("falls back to the first entry when no kimi-for-coding is present", async () => {
    mock = mockFetch(() =>
      jsonResponse({
        data: [{ id: "k2p7-beta", display_name: "Beta K2.7", context_length: 1048576 }],
      }),
    );

    const result = await discoverKimiModelMetadata("tok-1");
    assert.equal(result.wireModelId, "k2p7-beta");
    assert.equal(result.modelDisplay, "Beta K2.7");
    assert.equal(result.contextLength, 1048576);
  });

  it("returns empty when the server replies non-2xx", async () => {
    mock = mockFetch(() => new Response("nope", { status: 401 }));
    const result = await discoverKimiModelMetadata("tok-1");
    assert.deepEqual(result, {});
  });

  it("returns empty when the response is malformed", async () => {
    mock = mockFetch(() => new Response("not json", { status: 200 }));
    const result = await discoverKimiModelMetadata("tok-1");
    assert.deepEqual(result, {});
  });

  it("returns empty when data is missing or empty", async () => {
    mock = mockFetch(() => jsonResponse({ data: [] }));
    const result = await discoverKimiModelMetadata("tok-1");
    assert.deepEqual(result, {});
  });

  it("omits optional fields when the server does not provide them", async () => {
    mock = mockFetch(() => jsonResponse({ data: [{ id: "kimi-for-coding" }] }));
    const result = await discoverKimiModelMetadata("tok-1");
    assert.deepEqual(result, { wireModelId: "kimi-for-coding" });
  });

  it("respects KIMI_CODE_BASE_URL when computing the discovery endpoint", async () => {
    process.env.KIMI_CODE_BASE_URL = "https://proxy.example.com/kimi";
    mock = mockFetch(() =>
      jsonResponse({ data: [{ id: "kimi-for-coding", context_length: 100 }] }),
    );

    await discoverKimiModelMetadata("tok-1");
    assert.equal(mock.calls[0]?.url, "https://proxy.example.com/kimi/v1/models");
  });
});
