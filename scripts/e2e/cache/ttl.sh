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
source "$SCRIPT_DIR/../common.sh"

# ---------------------------------------------------------------------------
# Test 4: Prompt Cache TTL
# ---------------------------------------------------------------------------
cache_ttl_check() {
  if [ "$KIMI_E2E_SKIP_CACHE" = "1" ]; then
    log "=== Test 4: Prompt Cache TTL (skipped) ==="
    return 0
  fi

  log "=== Test 4: Prompt Cache TTL (Anthropic endpoint) ==="
  if [ "$KIMI_E2E_VERBOSE" = "1" ]; then
    log "+ cache_key=$KIMI_E2E_CACHE_KEY intervals=$KIMI_E2E_CACHE_INTERVALS repeat=$KIMI_E2E_CACHE_REPEAT"
  fi

  python3 - <<'PY'
import json
import os
import sys
import time
import urllib.request
import urllib.error

api_key = os.environ["KIMI_API_KEY"]
cache_key = os.environ["KIMI_E2E_CACHE_KEY"]
intervals = [int(x) for x in os.environ["KIMI_E2E_CACHE_INTERVALS"].split(",") if x.strip()]
repeat = int(os.environ["KIMI_E2E_CACHE_REPEAT"])
verbose = os.environ.get("KIMI_E2E_VERBOSE", "1") == "1"

long_text = (
    f"cache-key:{cache_key}\n" +
    ("This is meaningless filler text for testing Kimi Prompt Cache TTL. " * repeat) +
    "\n\nReply with only: ok"
)
headers = {
    "x-api-key": api_key,
    "anthropic-version": "2023-06-01",
    "content-type": "application/json",
    "User-Agent": "KimiCLI/1.44.0",
    "X-Msh-Platform": "kimi_cli",
    "X-Msh-Version": "1.44.0",
}

def make_payload(round_key):
    text = long_text.replace(f"cache-key:{cache_key}", f"cache-key:{round_key}")
    return {
        "model": os.environ["KIMI_E2E_WIRE_MODEL"],
        "max_tokens": 100,
        "prompt_cache_key": round_key,
        "messages": [{"role": "user", "content": [
            {"type": "text", "text": text, "cache_control": {"type": "ephemeral"}},
        ]}],
    }

def send(label, body_payload):
    body = json.dumps(body_payload).encode("utf-8")
    req = urllib.request.Request(
        (os.environ.get("KIMI_CODE_BASE_URL", "https://api.kimi.com/coding/v1").rstrip("/") + "/messages"),
        data=body, headers=headers, method="POST",
    )
    start = time.time()
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            raw = resp.read().decode("utf-8")
            elapsed = time.time() - start
            data = json.loads(raw)
            usage = data.get("usage", {})
            cache_read = max(
                int(usage.get("cache_read_input_tokens", 0) or 0),
                int(usage.get("cached_tokens", 0) or 0),
            )
            cache_create = int(usage.get("cache_creation_input_tokens", 0) or 0)
            input_tokens = int(usage.get("input_tokens", 0) or 0)
            print(f"[{time.strftime('%X')}] {label}: status=200 elapsed={elapsed:.2f}s input={input_tokens} cache_read={cache_read} cache_create={cache_create}", flush=True)
            if verbose:
                print(f"usage={json.dumps(usage, ensure_ascii=False)}", flush=True)
            return cache_read
    except urllib.error.HTTPError as e:
        err_body = e.read().decode("utf-8", errors="replace")
        print(f"[{time.strftime('%X')}] {label}: status={e.code} body={err_body}", flush=True)
        return -1
    except Exception as e:
        print(f"[{time.strftime('%X')}] {label}: request failed: {e}", flush=True)
        return -1

import concurrent.futures, copy

def run_probe(target):
    """Independent round: warmup -> sleep -> single probe. Returns (target, hit)."""
    round_key = f"{cache_key}-{target}s"
    p = make_payload(round_key)
    print(f"--- Round {target}s: warmup (key={round_key}) ---", flush=True)
    warmup_cache_read = send(f"warmup_{target}s", p)
    if warmup_cache_read < 0:
        raise RuntimeError(f"warmup failed for {target}s probe")
    print(f"[round {target}s] sleeping {target}s...", flush=True)
    time.sleep(target)
    cache_read = send(f"probe_at_{target}s", p)
    if cache_read < 0:
        raise RuntimeError(f"request failed for {target}s probe")
    hit = cache_read > 0
    print(f"[round {target}s] result: {'HIT' if hit else 'MISS'}\n", flush=True)
    return (target, hit)

# Run all intervals concurrently
with concurrent.futures.ThreadPoolExecutor(max_workers=len(intervals)) as pool:
    futures = {pool.submit(run_probe, t): t for t in intervals}
    probe_results = []
    for f in concurrent.futures.as_completed(futures):
        probe_results.append(f.result())

probe_results.sort()

# --- Conclusion ---
print()
hits = [t for t, hit in probe_results if hit]
misses = [t for t, hit in probe_results if not hit]
summary = " | ".join(f"{t}s={'HIT' if hit else 'MISS'}" for t, hit in probe_results)
print(f"Summary: {summary}")
if hits and misses:
    last_hit = max(hits)
    first_miss = min(misses)
    if first_miss > last_hit:
        print(f"Conclusion: TTL is between {last_hit}s and {first_miss}s.")
    else:
        print(f"Conclusion: mixed results (hits: {hits}, misses: {misses}). Cache behavior may be non-deterministic.")
elif hits:
    print(f"Conclusion: TTL >= {max(hits)}s (all probes hit).")
elif misses:
    print(f"Conclusion: TTL < {min(misses)}s (all probes missed).")
else:
    print("Conclusion: no probes ran.")
PY
  printf '\n'
}

# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Run this focused suite
# ---------------------------------------------------------------------------
cache_ttl_check
log "E2E suite complete."
