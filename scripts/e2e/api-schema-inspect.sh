#!/bin/bash
set -euo pipefail

API_KEY="${KIMI_API_KEY:-${1:-}}"
if [ -z "$API_KEY" ]; then
  echo "Usage: KIMI_API_KEY=sk-... $0"
  echo "   or: $0 sk-..."
  exit 1
fi
export KIMI_API_KEY="$API_KEY"

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

SCHEMA_OUTPUT="${KIMI_E2E_SCHEMA_OUTPUT:-$(mktemp -t kimi-api-schema-XXXXXX.json)}"
SCHEMA_BASELINE="${KIMI_E2E_SCHEMA_BASELINE:-}"
export SCHEMA_OUTPUT SCHEMA_BASELINE

python3 - <<'PY'
import json
import os
import sys
import urllib.error
import urllib.request

base_url = os.environ.get("KIMI_CODE_BASE_URL", "https://api.kimi.com/coding/v1").rstrip("/")
model_id = os.environ["KIMI_E2E_WIRE_MODEL"]
api_key = os.environ["KIMI_API_KEY"]
selected = [name.strip() for name in os.environ.get("KIMI_E2E_SCHEMA_ENDPOINTS", "models,openai,anthropic").split(",") if name.strip()]
known = {"models", "openai", "anthropic"}
unknown = sorted(set(selected) - known)
if unknown:
    print(f"FAIL: unsupported KIMI_E2E_SCHEMA_ENDPOINTS values: {', '.join(unknown)}")
    sys.exit(1)

headers = {
    "User-Agent": "KimiCLI/1.44.0",
    "X-Msh-Platform": "kimi_cli",
    "X-Msh-Version": "1.44.0",
    "Content-Type": "application/json",
}

def request_json(name):
    if name == "models":
        url = f"{base_url}/models"
        request_headers = {**headers, "Authorization": f"Bearer {api_key}", "Accept": "application/json"}
        payload = None
    elif name == "openai":
        url = f"{base_url}/chat/completions"
        request_headers = {**headers, "Authorization": f"Bearer {api_key}"}
        payload = {
            "model": model_id,
            "max_completion_tokens": 16,
            "messages": [{"role": "user", "content": "Reply with OK."}],
        }
    else:
        url = f"{base_url}/messages"
        request_headers = {**headers, "x-api-key": api_key, "anthropic-version": "2023-06-01"}
        payload = {
            "model": model_id,
            "max_tokens": 16,
            "messages": [{"role": "user", "content": [{"type": "text", "text": "Reply with OK."}]}],
        }

    body = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(url, data=body, headers=request_headers, method="GET" if body is None else "POST")
    with urllib.request.urlopen(request, timeout=90) as response:
        return response.status, json.load(response)

def shape(value):
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, str):
        return "string"
    if isinstance(value, (int, float)):
        return "number"
    if isinstance(value, list):
        item_shapes = {json.dumps(shape(item), sort_keys=True, separators=(",", ":")) for item in value}
        return {"array": [json.loads(item) for item in sorted(item_shapes)]}
    if isinstance(value, dict):
        return {"object": {key: shape(value[key]) for key in sorted(value)}}
    raise TypeError(f"unsupported JSON value: {type(value)!r}")

snapshot = {"version": 1, "endpoints": {}}
for endpoint in selected:
    try:
        status, payload = request_json(endpoint)
    except urllib.error.HTTPError as error:
        print(f"FAIL {endpoint}: HTTP {error.code}: {error.read().decode('utf-8', errors='replace')[:500]}")
        sys.exit(1)
    except Exception as error:
        print(f"FAIL {endpoint}: {error}")
        sys.exit(1)
    snapshot["endpoints"][endpoint] = shape(payload)
    print(f"PASS {endpoint}: HTTP {status}")

output = os.environ["SCHEMA_OUTPUT"]
with open(output, "w", encoding="utf-8") as handle:
    json.dump(snapshot, handle, ensure_ascii=False, indent=2, sort_keys=True)
    handle.write("\n")
print(f"Schema snapshot: {output}")
PY

if [ -n "$SCHEMA_BASELINE" ]; then
  if [ ! -f "$SCHEMA_BASELINE" ]; then
    echo "FAIL: schema baseline does not exist: $SCHEMA_BASELINE" >&2
    exit 1
  fi
  if diff -u "$SCHEMA_BASELINE" "$SCHEMA_OUTPUT"; then
    echo "PASS: API schema matches baseline"
  else
    echo "FAIL: API schema differs from baseline" >&2
    exit 1
  fi
fi
