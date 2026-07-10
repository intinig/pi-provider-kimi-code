#!/bin/bash
set -euo pipefail

API_KEY="${KIMI_API_KEY:-${1:-}}"

if [ -z "$API_KEY" ]; then
  echo "Usage: KIMI_API_KEY=sk-... $0"
  echo "   or: $0 sk-..."
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
KIMI_API_KEY="$API_KEY" "$SCRIPT_DIR/e2e/model-contract.sh"
