# Pi extension for Kimi Code

[![npm](https://img.shields.io/npm/v/pi-provider-kimi-code)](https://www.npmjs.com/package/pi-provider-kimi-code)
[![license](https://img.shields.io/npm/l/pi-provider-kimi-code)](./LICENSE)

**Use Kimi Code in Pi without losing the Kimi-specific bits.**

Pi gives you the harness and extension ecosystem. Kimi CLI gives you the official Kimi Code path. This package sits between them: Kimi Code as a Pi provider, plus the details the basic provider keeps simple — file uploads, cache behavior, session reuse, and a base for Kimi-native tools.

## Why this exists

Pi already has a built-in `kimi-coding` provider (see [`pi.dev/docs/.../providers`](https://pi.dev/docs/latest/providers)). It is good basic support: point Pi at Kimi Code and start coding.

This extension is for the next layer. If you are building real Pi workflows, the Kimi-specific details start to matter:

- **Files should go through Kimi's Files API.** Large images are uploaded to `/files` and referenced as `ms://` IDs instead of being sent as huge inline base64 payloads.
- **Cache behavior should be visible.** Kimi caches by content prefix, not by `prompt_cache_key`. This repo measures that behavior and keeps the provider aligned with it.
- **Existing Kimi sessions should carry over.** If you already use `kimi-cli`, this extension can reuse that login instead of making you manage another API key.
- **Protocol choice should stay available.** The default is OpenAI-compatible mode, but Anthropic-compatible mode is still there when your Pi setup needs it.

> On prompt caching: the built-in provider works fine. Kimi's Coding endpoint caches by content prefix hash automatically — neither `cache_control` markers nor `prompt_cache_key` actually drive cache hits. See [docs/caching.md](docs/caching.md) for measurements.

## Who is this for?

- You use Pi as your coding harness and want Kimi Code inside that workflow.
- You already use `kimi-cli`, but want Pi's extensions, skills, prompts, themes, and custom UI pieces around the same Kimi Code account.
- You are building on top of Pi and need the Kimi-specific parts to behave predictably: uploads, cache behavior, model metadata, and protocol choice.

Pay-per-token via `KIMI_API_KEY` still works if you just want to try Kimi in CI or without a subscription.

## What this package adds

- **Kimi account login in Pi** — sign in with your Kimi Code account. `KIMI_API_KEY` still works for CI or pay-per-token use.
- **`kimi-cli` session reuse** — if you already signed in with the official CLI, this extension can read `~/.kimi/credentials/kimi-code.json` and skip another browser login.
- **Kimi Files API upload** — large images are uploaded to `/v1/files` and sent as `ms://` references instead of huge inline base64 payloads.
- **Measured cache behavior** — Kimi's Coding endpoint caches by content prefix hash with TTL ≥ 5 minutes. This repo documents what changes the cache and what does not.
- **Live model metadata** — name, context window, reasoning support, and image-input support refresh from Kimi's `/v1/models` endpoint at login / refresh time.
- **Protocol choice** — OpenAI-compatible mode is the default. Anthropic-compatible mode is still available with `KIMI_CODE_PROTOCOL=anthropic`.
- **Stream cleanup** — Kimi occasionally emits placeholder text during thinking-only responses; this extension hides those blocks before they reach the Pi UI.
- **No build step** — Pi loads the TypeScript extension directly.

## Install

From npm:

```bash
pi install npm:pi-provider-kimi-code
```

Or load a local checkout without installing:

```bash
pi -e /path/to/pi-provider-kimi-code
```

### Install from GitHub Release tarball

If you prefer not to use npm, download the tarball from the [latest release](https://github.com/Leechael/pi-provider-kimi-code/releases/latest), extract it, and install from the local path:

```bash
# Download and extract
curl -L https://github.com/Leechael/pi-provider-kimi-code/releases/latest/download/pi-provider-kimi-code.tar.gz | tar -xz -C /tmp

# Install from the extracted directory
pi install /tmp/pi-provider-kimi-code
```

## Sign in

### Browser login

Inside Pi, run:

```
/login kimi-coding
```

A browser tab opens, you sign into your Kimi account, and credentials are stored at `~/.pi/agent/auth.json`. Tokens refresh automatically.

### Already logged in via `kimi-cli`?

If `~/.kimi/credentials/kimi-code.json` exists, `/login kimi-coding` reads that file, refreshes the access token if needed, and finishes without opening a browser. The `kimi-cli` credential file is read-only from this extension's perspective — it is never overwritten. Set `KIMI_SHARE_DIR` to point at a non-default location.

### API key

For CI or pay-per-token use, set `KIMI_API_KEY`:

```bash
KIMI_API_KEY=sk-... pi
```

## Model

This provider publishes one Pi model ID:

```
kimi-coding/kimi-for-coding
```

Kimi keeps the Coding model behind aliases, so this provider does not hardcode a long model list. When you log in or refresh your token, it asks Kimi for the current model info and updates what Pi sees. If your account is on a newer rollout or an internal test, Pi can pick up the latest model name and context size without waiting for this package to release.

The fallback values are:

- Context window: `262144` tokens
- Max output: `32000` tokens
- Input: text and image
- Reasoning: enabled

Kimi K2.6 supports Pi's reasoning levels. This provider maps them to Kimi's current reasoning efforts:

- `off` / `none` — reasoning disabled
- `minimal` / `low` — low effort
- `medium` — medium effort
- `high` / `xhigh` — high effort

If Kimi reports a larger context window, the provider uses that value. You can also override the advertised context or model name with `KIMI_MODEL_MAX_CONTEXT_SIZE` / `KIMI_MODEL_NAME`; see [docs/ENV.md](docs/ENV.md).

Select it inside Pi:

```
/model kimi-coding/kimi-for-coding
```

## Common knobs

Most users do not need environment variables. Two are worth knowing:

- `KIMI_API_KEY` — static API key for CI or pay-per-token use.
- `KIMI_CODE_PROTOCOL` — `openai` by default; set to `anthropic` if your Pi setup needs Anthropic-compatible requests.

The full list, including base URL overrides, `kimi-cli` path overrides, upload tuning, debug logs, and model metadata overrides, lives in [docs/ENV.md](docs/ENV.md).

## Optional Moonshot tools

This extension can also register Kimi Coding's server-side `moonshot_search` and `moonshot_fetch` tools. These are Moonshot services behind the Kimi Coding endpoint, not built-in Pi web tools, and they stay disabled until you opt in.

Config files are JSON:

- Home: `~/.pi/pi-provider-kimi-code.json`
- Project override: `<cwd>/.pi/pi-provider-kimi-code.json`

Project config overrides home config with a deep merge. Missing files or missing keys mean both tools stay off.

```json
{
  "tools": {
    "moonshot_search": { "enabled": true, "default_collapsed": true },
    "moonshot_fetch": { "enabled": true, "default_collapsed": true }
  }
}
```

Inside Pi, run `/kimi-settings` to see your current Kimi usage summary and edit the home or project config. Enabling or disabling a tool also updates the active tool set for the current session.

Both tools require `/login kimi-coding` OAuth credentials and an active Kimi Code Plan. `KIMI_API_KEY` is not used for these tools. Downstream users may still see subscription or whitelist errors if their account is not entitled to the server-side search/fetch services.

`default_collapsed` controls only the TUI preview. The full tool result still goes to the model; setting it to `false` makes the result render expanded by default.

If you already use MCP-provided web search or fetch tools, pick one path for a session. Enabling both gives the model overlapping tools; these Moonshot tools are only available to the agent after the config file enables them.

## Notes

### Kimi CLI vs Pi

`kimi-cli` is Moonshot's official terminal agent. Pi is the harness you adapt to your own workflow: extensions, skills, prompts, themes, custom commands, status bars, and UI pieces. This package lets you keep Kimi Code as the model path while staying inside Pi.

### Cache behavior

Kimi's cache is content-based. It fires automatically when your prompt prefix matches an earlier request. `prompt_cache_key` and Anthropic `cache_control` markers do not control cache hits on the Coding endpoint.

See [docs/caching.md](docs/caching.md) for the measured behavior: TTL, cross-protocol cache reuse, 256-token prefix alignment, and the cases that invalidate cache.

### Protocol modes

Kimi's coding endpoint speaks both Anthropic and OpenAI dialects. This extension defaults to OpenAI-compatible mode.

`KIMI_CODE_PROTOCOL` supports:

- `openai` — default, uses `/coding/v1/chat/completions`
- `anthropic` — uses `/coding/v1/messages`

Use Anthropic mode if your Pi setup depends on Anthropic-style request or tool semantics.

### Why OpenAI-compatible mode is the default

The Anthropic-compatible protocol has an awkward tool-result shape: tool output is wrapped inside a `role: "user"` message. That is valid Anthropic format, but Kimi can sometimes read it like a real user message and continue from the wrong premise in multi-turn tool loops.

The OpenAI-compatible protocol uses a dedicated `role: "tool"` message, so the boundary is clearer. That is why this extension now defaults to `openai`. The Anthropic path stays available for setups that need it. See [issue #5](https://github.com/Leechael/pi-provider-kimi-code/issues/5) for details.

### Is this affiliated with Moonshot AI?

No. This is an independent extension. The login flow is derived from the public implementation in the open-source [`kimi-cli`](https://github.com/MoonshotAI/kimi-cli) repository.

## Troubleshooting

### `pi` reports `fetch failed` even though `curl` works

Pi runs on Node's `fetch` / undici stack, which handles `http_proxy` / `https_proxy` / `all_proxy` differently from `curl`. Verify those variables in the Pi process's environment. The bundled smoke-test script `scripts/test_e2e.sh` prints the effective proxy-related environment for easier debugging.

### `/login kimi-coding` prints a device code but the browser never opens

The login flow always prints a verification URL — opening it is the terminal's job. If your terminal or OS blocks auto-open, copy the URL and paste it into a browser manually.

### "Access denied" or subscription errors after a successful login

Your Moonshot account needs an active Kimi Code subscription for the provider to do anything useful. If the same account works in `kimi-cli`, re-run `/login kimi-coding` to refresh credentials.

### Large images fail with a payload error

This extension uploads images over `KIMI_CODE_UPLOAD_THRESHOLD_BYTES` (default 1 MB) to Kimi's Files API and references them as `ms://`. Set `KIMI_CODE_DEBUG=1` to see upload decisions in the provider logs.

### Prompt cache never seems to hit

Kimi's cache is **content-based**: it fires automatically when your prompt prefix matches an earlier request, independent of any explicit cache key. If `cache_read_input_tokens` (Anthropic) or `cached_tokens` (OpenAI) stays at `0` across calls, something in the prompt is varying between turns. The usual suspects:

- On the Anthropic-compat endpoint, the `system` prompt or the `tools` array changed (e.g. an extension changed the tool set mid-session). Either fully invalidates the cache — see [docs/caching.md](docs/caching.md), Finding 11. OpenAI-compat endpoint not yet measured for this scenario.
- An `image_url` reference (`ms://<file_id>`) changed between turns. Same rule — see Finding 17.
- You're comparing across two cold `pi` invocations, not within a single session. Cache benefits accrue **within** a session; Pi's system/tools assembly drifts between sessions. See Finding 18.
- A timestamp, request ID, or randomized header is being interpolated into the prompt.
- The first ~256 tokens of the prompt differ between turns.

`PI_CACHE_RETENTION=none` skips `prompt_cache_key` injection but **does not** disable Kimi's caching (the cache is unconditional). For deterministic measurement, run `scripts/test_e2e.sh` with `KIMI_E2E_ONLY_CACHE=1`. See [docs/caching.md](docs/caching.md) for full mechanics.

### OpenAI-compatible tools complain about a `developer` role

In OpenAI mode this extension maps the `developer` role to `system` (Kimi's Coding endpoint does not recognize `developer`). If something in your toolchain expects `developer` to round-trip, use Anthropic mode instead.

## References

- Pi: [earendil-works/pi](https://github.com/earendil-works/pi)
- Upstream login implementation and feature request: [MoonshotAI/kimi-cli](https://github.com/MoonshotAI/kimi-cli) · [kimi-cli#757](https://github.com/MoonshotAI/kimi-cli/issues/757)
- Environment variables: [docs/ENV.md](docs/ENV.md)
- Testing guide: [docs/TESTING.md](docs/TESTING.md)
- Cache behavior: [docs/caching.md](docs/caching.md)
- Architecture notes: [docs/architecture.md](docs/architecture.md)

## Credits

Based on the login implementation from [`kimi-cli`](https://github.com/MoonshotAI/kimi-cli) by Moonshot AI. Built as a Pi extension by [@badlogic](https://github.com/badlogic).

## License

MIT
