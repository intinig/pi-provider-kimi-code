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
request = urllib.request.Request(
    f"{base_url}/models",
    headers={
        "Authorization": f"Bearer {os.environ['KIMI_API_KEY']}",
        "Accept": "application/json",
        "User-Agent": "KimiCLI/1.44.0",
        "X-Msh-Platform": "kimi_cli",
        "X-Msh-Version": "1.44.0",
    },
)
try:
    with urllib.request.urlopen(request, timeout=60) as response:
        payload = json.load(response)
except urllib.error.HTTPError as error:
    print(f"FAIL /models: HTTP {error.code}: {error.read().decode('utf-8', errors='replace')[:500]}")
    sys.exit(1)
except Exception as error:
    print(f"FAIL /models: {error}")
    sys.exit(1)

models = payload.get("data", payload) if isinstance(payload, dict) else payload
if not isinstance(models, list):
    print("FAIL /models: expected a JSON array or an object with data[]")
    sys.exit(1)

print(f"PASS /models: {len(models)} model(s)")
for model in models:
    if not isinstance(model, dict):
        continue
    efforts = model.get("think_efforts")
    normalized_efforts = None
    if isinstance(efforts, dict):
        normalized_efforts = {
            "support": efforts.get("support"),
            "valid_efforts": efforts.get("valid_efforts"),
            "default_effort": efforts.get("default_effort"),
        }
    capability = {
        "id": model.get("id"),
        "display_name": model.get("display_name"),
        "context_length": model.get("context_length"),
        "supports_thinking_type": model.get("supports_thinking_type"),
        "supports_reasoning": model.get("supports_reasoning"),
        "think_efforts": normalized_efforts,
        "protocol": model.get("protocol"),
        "supports_image_in": model.get("supports_image_in"),
        "supports_video_in": model.get("supports_video_in"),
    }
    print(json.dumps(capability, ensure_ascii=False, sort_keys=True))
PY
