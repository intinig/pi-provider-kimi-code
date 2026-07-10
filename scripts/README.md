# Scripts

This directory contains local checks, live Kimi API contract suites, Pi provider payload inspection tools, and cache experiments.

## Entry Points

| Script                     | Scope                     | Responsibility                                                          | Side effects                                                  |
| -------------------------- | ------------------------- | ----------------------------------------------------------------------- | ------------------------------------------------------------- |
| `test_e2e.sh`              | All live E2E suites       | Runs the focused E2E suites in their defined order.                     | Sends live API requests; cache suites can be slow and costly. |
| `list_models.sh`           | Compatibility entry point | Runs `e2e/model-contract.sh`.                                           | Reads the live model catalog.                                 |
| `test_payload_thinking.sh` | Compatibility entry point | Runs `e2e/thinking-effort-contract.sh`.                                 | Sends one request per selected protocol.                      |
| `probe_model.sh`           | Manual model probe        | Sends a targeted request for a specified model and prints the response. | Sends a live API request.                                     |

## Focused E2E Suites

Every suite in `e2e/` requires `KIMI_API_KEY`. The shared `e2e/common.sh` setup defines the default Coding API base URL, Pi model alias, wire model ID, Kimi client headers, cache controls, and logging.

| Script                            | Scope                             | Responsibility                                                                                                                            | Side effects                                                                                 |
| --------------------------------- | --------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| `e2e/model-contract.sh`           | Model catalog                     | Reads `/models` and reports model IDs, protocols, context limits, thinking metadata, and supported input modalities.                      | One `GET /models` request.                                                                   |
| `e2e/api-schema-inspect.sh`       | API response schema               | Writes normalized field-and-type snapshots for `/models`, `/chat/completions`, and `/messages`; optionally fails when a baseline differs. | One request per selected endpoint; writes a snapshot file.                                   |
| `e2e/smoke.sh`                    | Provider behavior                 | Runs Pi against OpenAI and Anthropic wire protocols across configured thinking levels.                                                    | Sends multiple live Pi requests.                                                             |
| `e2e/thinking-effort-contract.sh` | Dynamic thinking effort           | Selects a server-declared `think_efforts` value and verifies that each selected endpoint accepts root-level `thinking.effort`.            | Reads `/models`, then sends one request per selected protocol.                               |
| `e2e/provider-payload.sh`         | Provider wire payload             | Routes a Pi request through the local capture proxy and verifies the emitted wire model and root-level thinking payload.                  | Starts a loopback proxy and sends a live request; capture files are deleted unless retained. |
| `e2e/file-upload.sh`              | File upload                       | Uploads a generated image, then verifies an `ms://` image reference with the OpenAI endpoint.                                             | Downloads an image, uploads it, and sends a live request.                                    |
| `e2e/cache/ttl.sh`                | Cache retention                   | Measures cache behavior over configured wait intervals.                                                                                   | Sends requests and waits between them.                                                       |
| `e2e/cache/mechanisms.sh`         | Cache mechanism                   | Compares cache modes and protocol-specific behavior.                                                                                      | Sends repeated live requests.                                                                |
| `e2e/cache/identity.sh`           | Cache identity                    | Tests which request identity fields preserve or split cache reuse.                                                                        | Sends repeated live requests.                                                                |
| `e2e/cache/prefix.sh`             | Cache prefix                      | Tests cache behavior for shared prompt prefixes and edits.                                                                                | Sends repeated live requests.                                                                |
| `e2e/cache/parameters.sh`         | Cache parameters                  | Tests cache effects of model parameters, tools, and prompt options.                                                                       | Sends repeated live requests.                                                                |
| `e2e/cache/multimodal.sh`         | Cache concurrency and input types | Tests cache behavior for multimodal and concurrent requests.                                                                              | Sends repeated live requests.                                                                |

## API Schema Inspection

The schema inspector records only JSON structure: object field names, arrays, and primitive types. It does not retain API keys or response content.

```bash
KIMI_API_KEY=sk-... ./scripts/e2e/api-schema-inspect.sh
```

The default writes a snapshot to a temporary file. Save a snapshot as the accepted baseline, then compare later API responses against it:

```bash
KIMI_API_KEY=sk-... KIMI_E2E_SCHEMA_OUTPUT=/tmp/kimi-schema-baseline.json \
  ./scripts/e2e/api-schema-inspect.sh

KIMI_API_KEY=sk-... KIMI_E2E_SCHEMA_BASELINE=/tmp/kimi-schema-baseline.json \
  ./scripts/e2e/api-schema-inspect.sh
```

Use `KIMI_E2E_SCHEMA_ENDPOINTS=models,openai,anthropic` to select endpoints. The default selects all three. `KIMI_E2E_WIRE_MODEL` controls the model in endpoint probes, and `KIMI_CODE_BASE_URL` can point the suite at a local mock server.

## Capture Proxy Tools

| Script                             | Responsibility                                                                                                                      |
| ---------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `kimi-compat/capture_proxy.mjs`    | Forwards Kimi HTTP traffic, captures request and response metadata, and redacts `Authorization` and `x-api-key` before persistence. |
| `kimi-compat/inspect_captures.mjs` | Summarizes saved capture files.                                                                                                     |
| `kimi-compat/dump_raw_request.mjs` | Prints one saved request for manual inspection.                                                                                     |

`CAPTURE_DIR` selects the capture directory. `e2e/provider-payload.sh` creates one under `/tmp` and removes it unless `KIMI_E2E_KEEP_CAPTURES=1`.
