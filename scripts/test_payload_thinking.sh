#!/bin/bash
set -euo pipefail

# Compatibility entry point for the live thinking-effort contract suite.
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
exec "$SCRIPT_DIR/e2e/thinking-effort-contract.sh" "$@"
