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

suites=(
  "e2e/model-contract.sh"
  "e2e/api-schema-inspect.sh"
  "e2e/smoke.sh"
  "e2e/thinking-effort-contract.sh"
  "e2e/provider-payload.sh"
  "e2e/file-upload.sh"
  "e2e/cache/ttl.sh"
  "e2e/cache/mechanisms.sh"
  "e2e/cache/identity.sh"
  "e2e/cache/prefix.sh"
  "e2e/cache/parameters.sh"
  "e2e/cache/multimodal.sh"
)

for suite in "${suites[@]}"; do
  printf '\n=== Running %s ===\n' "$suite"
  "$SCRIPT_DIR/$suite"
done

printf '\nE2E tests complete.\n'
