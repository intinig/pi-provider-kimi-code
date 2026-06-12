# Plan — Kimi Special Capabilities: Thinking Type and Unified Datasource Tool

Status: implemented in branch, not committed unless explicitly requested for this plan file.

## Context record

Upstream reviewed: `/Users/leechael/workshop/github/kimi-code` commits `933cf672..1cb49dba`.

Relevant upstream additions:

- `/models` exposes `supports_thinking_type: "only" | "no" | "both"`.
- Kimi datasource plugin calls `POST https://api.kimi.com/coding/v1/tools`.
- Datasource methods:
  - `get_data_source_desc`
  - `call_data_source_tool`
- Official datasource names:
  - `stock_finance_data`
  - `yahoo_finance`
  - `world_bank_open_data`
  - `tianyancha`
  - `arxiv`
  - `scholar`
  - `yuandian_law`
- Kimi Code advertises video-capable model metadata, but the OAuth coding chat endpoint currently rejects `video_url` parts.

Product positioning for this provider:

- The core LLM API surface is mostly complete.
- New value should come from tools.
- Search and fetch remain distinct capabilities.
- Datasource variants should not be split into one tool per datasource; use one unified datasource tool.

## Scope

Implement three opt-in tools:

1. `moonshot_search`
2. `moonshot_fetch`
3. `kimi_datasource` for datasource APIs

Also implement `supports_thinking_type` model metadata support.

Out of scope:

- Changing pi core to support native audio/video message parts.
- Exposing a video analysis tool through the OAuth coding endpoint.
- Registering one tool per datasource.
- Hard-coding every datasource sub-API as a separate tool.
- Auto-enabling any tool by default.

## `supports_thinking_type`

Read `supports_thinking_type` from `/models` and prefer it over legacy `supports_reasoning`.

Mapping:

| Server value    | Provider behavior                                     |
| --------------- | ----------------------------------------------------- |
| `only`          | reasoning supported; requests force thinking enabled  |
| `both`          | reasoning supported; user/session can toggle thinking |
| `no`            | reasoning unsupported; do not send thinking params    |
| missing/unknown | fall back to `supports_reasoning`                     |

Env override mapping:

- `KIMI_MODEL_CAPABILITIES=always_thinking` -> `supportsThinkingType: "only"`
- `KIMI_MODEL_CAPABILITIES=thinking` -> `supportsThinkingType: "both"`
- no thinking capability token -> `supportsThinkingType: "no"`

## Tool config

```json
{
  "tools": {
    "moonshot_search": { "enabled": false, "default_collapsed": true },
    "moonshot_fetch": { "enabled": false, "default_collapsed": true },
    "kimi_datasource": { "enabled": false, "default_collapsed": true }
  }
}
```

## `kimi_datasource` datasource contract

Input:

```json
{
  "data_source_name": "arxiv",
  "api_name": "optional string",
  "params": "optional object"
}
```

Behavior:

- Without `api_name`: call `get_data_source_desc` for `data_source_name`.
- With `api_name`: call `call_data_source_tool` with `data_source_name`, `api_name`, and `params`.

Supported datasource names:

- `stock_finance_data`
- `yahoo_finance`
- `world_bank_open_data`
- `tianyancha`
- `arxiv`
- `scholar`
- `yuandian_law`

Endpoint overrides:

- `KIMI_CODE_BASE_URL` / `KIMI_BASE_URL` affect search and fetch after `/v1` derivation.
- `KIMI_DATASOURCE_API_URL` overrides the datasource `/tools` endpoint.

## Video status

Video analysis is intentionally not exposed as a tool. Live checks showed `POST /coding/v1/files` with `purpose=video` succeeds, but `POST /coding/v1/chat/completions` rejects `video_url` content parts with `invalid_request_error`. Re-enable only after the coding endpoint accepts Kimi multimodal video payloads or a separate supported endpoint is configured.

## Acceptance tests

### Thinking type

- `/models` `supports_thinking_type: "only"` stores `supportsThinkingType: "only"` and enables reasoning.
- `/models` `"no"` suppresses reasoning.
- `/models` missing/unknown value falls back to `supports_reasoning`.
- Request payload suppresses thinking for `"no"`.
- Request payload forces thinking for `"only"`.
- `KIMI_MODEL_CAPABILITIES=always_thinking` maps to `supportsThinkingType: "only"`.
- Stale `supportsThinkingType` is cleared when later extras only include `supportsReasoning`.

### Tools

- Missing config registers no tools.
- Each enabled tool registers independently.
- `moonshot_search` calls `/search` with expected body and headers.
- `moonshot_fetch` calls `/fetch` with expected body and headers.
- `kimi_datasource` without `api_name` calls `get_data_source_desc`.
- `kimi_datasource` with `api_name` calls `call_data_source_tool`.
- Missing OAuth credentials returns an actionable error and does not call fetch.
- 401 refresh behavior matches existing OAuth refresh path.
- Non-2xx response returns a tool error with status and response text.
- `is_success: false` datasource response returns server error text.
- Tool rendering respects `default_collapsed`.
- `KIMI_CODE_BASE_URL` and `KIMI_DATASOURCE_API_URL` endpoint overrides are honored.
