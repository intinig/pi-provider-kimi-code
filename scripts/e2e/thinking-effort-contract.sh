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

python3 - <<'PY'
import json
import os
import sys
import urllib.error
import urllib.request

base_url = os.environ.get("KIMI_CODE_BASE_URL", "https://api.kimi.com/coding/v1").rstrip("/")
model_id = os.environ["KIMI_E2E_WIRE_MODEL"]
api_key = os.environ["KIMI_API_KEY"]
protocols = [value.strip() for value in os.environ.get("KIMI_E2E_EFFORT_PROTOCOLS", "openai,anthropic").split(",") if value.strip()]

common_headers = {
    "User-Agent": "KimiCLI/1.44.0",
    "X-Msh-Platform": "kimi_cli",
    "X-Msh-Version": "1.44.0",
    "Content-Type": "application/json",
}

def request_json(url, headers, payload=None):
    body = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(url, data=body, headers=headers, method="GET" if body is None else "POST")
    with urllib.request.urlopen(request, timeout=90) as response:
        return response.status, json.loads(response.read())

try:
    _, catalog = request_json(
        f"{base_url}/models",
        {**common_headers, "Authorization": f"Bearer {api_key}", "Accept": "application/json"},
    )
except urllib.error.HTTPError as error:
    print(f"FAIL /models: HTTP {error.code}: {error.read().decode('utf-8', errors='replace')[:500]}")
    sys.exit(1)
except Exception as error:
    print(f"FAIL /models: {error}")
    sys.exit(1)

models = catalog.get("data", catalog) if isinstance(catalog, dict) else catalog
model = next((item for item in models if isinstance(item, dict) and item.get("id") == model_id), None)
if model is None:
    print(f"FAIL /models: model {model_id!r} was not returned")
    sys.exit(1)

efforts = model.get("think_efforts")
if not isinstance(efforts, dict) or efforts.get("support") is not True:
    print(f"SKIP: {model_id} does not advertise think_efforts support")
    sys.exit(0)
valid = efforts.get("valid_efforts")
if not isinstance(valid, list) or not all(isinstance(value, str) and value for value in valid):
    print(f"FAIL: {model_id} advertises think_efforts.support=true without valid_efforts[]")
    sys.exit(1)

chosen = os.environ.get("KIMI_E2E_EFFORT") or efforts.get("default_effort") or valid[0]
if chosen not in valid:
    print(f"FAIL: requested effort {chosen!r} is not in server-declared valid_efforts={valid!r}")
    sys.exit(1)

print(f"Model: {model_id}; valid_efforts={valid!r}; selected={chosen!r}")
errors = []
for protocol in protocols:
    if protocol == "openai":
        url = f"{base_url}/chat/completions"
        headers = {**common_headers, "Authorization": f"Bearer {api_key}"}
        payload = {
            "model": model_id,
            "max_completion_tokens": 128,
            "messages": [{"role": "user", "content": "What is 17 * 23? Reply with just the number."}],
            "thinking": {"type": "enabled", "effort": chosen},
        }
    elif protocol == "anthropic":
        url = f"{base_url}/messages"
        headers = {**common_headers, "x-api-key": api_key, "anthropic-version": "2023-06-01"}
        payload = {
            "model": model_id,
            "max_tokens": 128,
            "messages": [{"role": "user", "content": [{"type": "text", "text": "What is 17 * 23? Reply with just the number."}]}],
            "thinking": {"type": "enabled", "effort": chosen},
        }
    else:
        errors.append(f"unsupported protocol selector: {protocol}")
        continue
    try:
        status, _ = request_json(url, headers, payload)
        print(f"PASS {protocol}: thinking.effort={chosen!r} accepted (HTTP {status})")
    except urllib.error.HTTPError as error:
        errors.append(f"{protocol}: HTTP {error.code}: {error.read().decode('utf-8', errors='replace')[:500]}")
    except Exception as error:
        errors.append(f"{protocol}: {error}")

if errors:
    print("FAIL thinking effort contract:")
    print("\n".join(f"  {error}" for error in errors))
    sys.exit(1)
PY
