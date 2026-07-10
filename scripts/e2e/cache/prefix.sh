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
# Test 4f: System Prompt & Tools in Cached Prefix
# ---------------------------------------------------------------------------
# Anthropic API treats `system` and `tools` as fields separate from `messages`.
# We probe whether changing them invalidates the messages-level cache.
#
# F0 (baseline): identical system + messages -> expect full HIT
# F1: same messages, different system text -> does messages cache survive?
# F2: same messages+system, add tools on probe -> impact?
# F3: warm with system, probe without system -> impact?
system_tools_cache_check() {
  if [ "${KIMI_E2E_SKIP_SYSTEM_TOOLS_CACHE:-0}" = "1" ]; then
    log "=== Test 4f: System / Tools Cache Participation (skipped) ==="
    return 0
  fi

  log "=== Test 4f: System / Tools Cache Participation (Anthropic endpoint) ==="

  python3 - <<'PY'
import json
import os
import time
import urllib.error
import urllib.request
import uuid

api_key = os.environ["KIMI_API_KEY"]
verbose = os.environ.get("KIMI_E2E_VERBOSE", "1") == "1"
repeat = int(os.environ.get("KIMI_E2E_CACHE_REPEAT", "2000"))

filler = "This is meaningless filler text for testing system/tools cache impact. " * repeat

headers = {
    "x-api-key": api_key,
    "anthropic-version": "2023-06-01",
    "content-type": "application/json",
    "User-Agent": "KimiCLI/1.44.0",
    "X-Msh-Platform": "kimi_cli",
    "X-Msh-Version": "1.44.0",
}

DEMO_TOOLS = [{
    "name": "Read",
    "description": "Read a file from the filesystem.",
    "input_schema": {
        "type": "object",
        "properties": {"path": {"type": "string"}},
        "required": ["path"],
    },
}]

def build_payload(salt, system=None, tools=None):
    text = f"variant:{salt}\n{filler}\n\nReply with only: ok"
    payload = {
        "model": os.environ["KIMI_E2E_WIRE_MODEL"],
        "max_tokens": 50,
        "messages": [{"role": "user", "content": [{"type": "text", "text": text}]}],
    }
    if system is not None:
        payload["system"] = system
    if tools is not None:
        payload["tools"] = tools
    return payload

def send(label, payload):
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        (os.environ.get("KIMI_CODE_BASE_URL", "https://api.kimi.com/coding/v1").rstrip("/") + "/messages"),
        data=body, headers=headers, method="POST",
    )
    start = time.time()
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            elapsed = time.time() - start
            u = data.get("usage", {})
            cache_read = max(
                int(u.get("cache_read_input_tokens", 0) or 0),
                int(u.get("cached_tokens", 0) or 0),
            )
            prompt = int(u.get("prompt_tokens", 0) or u.get("input_tokens", 0) or 0)
            print(f"[{time.strftime('%X')}] {label}: prompt={prompt} cache_read={cache_read} elapsed={elapsed:.2f}s", flush=True)
            return cache_read, prompt
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")[:300]
        print(f"[{time.strftime('%X')}] {label}: HTTP {e.code} {body}", flush=True)
        return -1, -1
    except Exception as e:
        print(f"[{time.strftime('%X')}] {label}: failed: {e}", flush=True)
        return -1, -1

def run(name, warm_payload, probe_payload):
    print(f"--- {name} ---", flush=True)
    send(f"{name}_warm", warm_payload)
    time.sleep(3)
    return send(f"{name}_probe", probe_payload)

# F0 baseline: identical system + messages -> expect full HIT
salt0 = f"F0-{uuid.uuid4()}"
sys_helpful = "You are a helpful assistant."
p0 = build_payload(salt0, system=sys_helpful)
f0_read, f0_prompt = run("F0_baseline", p0, p0)

# F1: same messages, different system
salt1 = f"F1-{uuid.uuid4()}"
sys_concise = "You are a concise coding expert. Reply briefly."
p1a = build_payload(salt1, system=sys_helpful)
p1b = build_payload(salt1, system=sys_concise)
f1_read, f1_prompt = run("F1_system_changed", p1a, p1b)

# F2: same messages+system, add tools on probe
salt2 = f"F2-{uuid.uuid4()}"
p2a = build_payload(salt2, system=sys_helpful)
p2b = build_payload(salt2, system=sys_helpful, tools=DEMO_TOOLS)
f2_read, f2_prompt = run("F2_tools_added", p2a, p2b)

# F3: warm with system, probe without
salt3 = f"F3-{uuid.uuid4()}"
p3a = build_payload(salt3, system=sys_helpful)
p3b = build_payload(salt3)
f3_read, f3_prompt = run("F3_system_removed", p3a, p3b)

# Analysis
print()
print("Results:")
print(f"  F0 baseline:        cache_read={f0_read} / prompt={f0_prompt}")
print(f"  F1 system changed:  cache_read={f1_read} / prompt={f1_prompt}")
print(f"  F2 tools added:     cache_read={f2_read} / prompt={f2_prompt}")
print(f"  F3 system removed:  cache_read={f3_read} / prompt={f3_prompt}")

print()
if f0_read > 0:
    def ratio(r):
        return (r / f0_read) if (r >= 0 and f0_read > 0) else 0
    r1 = ratio(f1_read)
    r2 = ratio(f2_read)
    r3 = ratio(f3_read)
    print(f"Ratios vs F0 baseline: F1={r1:.1%}  F2={r2:.1%}  F3={r3:.1%}")
    if r1 > 0.9 and r2 > 0.9 and r3 > 0.9:
        print("Verdict: system & tools cache INDEPENDENTLY from messages. Changing them does not invalidate the messages cache.")
    elif r1 < 0.2 and r2 < 0.2 and r3 < 0.2:
        print("Verdict: system & tools are part of the PREFIX. Changing them fully invalidates cache.")
    else:
        print("Verdict: mixed behavior. Some changes invalidate (or partially invalidate) the cache.")
else:
    print("Verdict: F0 baseline failed; cannot interpret.")
PY
  printf '\n'
}

# ---------------------------------------------------------------------------
# Test 4g: Large Delta Cross-Boundary
# ---------------------------------------------------------------------------
# Verifies that a single turn whose new content crosses multiple 256-token
# chunk boundaries still caches the intermediate chunks for the NEXT turn.
#
# Sends three payloads sequentially:
#   P1 ~5K tokens   (small base)
#   P2 ~15K tokens  (P1 + ~10K assistant/user middle)
#   P3 ~15K + 50    (P2 + tiny follow-up)
# Expects:
#   - P2 cache_read ~ chunk-floor of P1
#   - P3 cache_read ~ chunk-floor of P2 (proves the 10K middle was cached past
#     the P1 boundary)
large_delta_check() {
  if [ "${KIMI_E2E_SKIP_LARGE_DELTA:-0}" = "1" ]; then
    log "=== Test 4g: Large Delta Cross-Boundary (skipped) ==="
    return 0
  fi

  log "=== Test 4g: Large Delta Cross-Boundary (Anthropic endpoint) ==="

  python3 - <<'PY'
import json
import os
import time
import urllib.error
import urllib.request
import uuid

api_key = os.environ["KIMI_API_KEY"]
verbose = os.environ.get("KIMI_E2E_VERBOSE", "1") == "1"

base_filler = "small text " * 400  # ~5K tokens base
mid_filler = "midfiller text padding for cross-boundary delta test " * 1500  # ~10K tokens

headers = {
    "x-api-key": api_key,
    "anthropic-version": "2023-06-01",
    "content-type": "application/json",
    "User-Agent": "KimiCLI/1.44.0",
    "X-Msh-Platform": "kimi_cli",
    "X-Msh-Version": "1.44.0",
}

salt = f"largedelta-{uuid.uuid4()}"
base_text = f"base:{salt}\n{base_filler}\n\nWe'll have a multi-turn chat. Reply ok-1."

def build(layer):
    msgs = [{"role": "user", "content": [{"type": "text", "text": base_text}]}]
    if layer >= 2:
        msgs.append({"role": "assistant", "content": [{"type": "text", "text": "ok-1"}]})
        msgs.append({"role": "user", "content": [{"type": "text", "text": f"mid:{salt}\n{mid_filler}\n\nNow reply ok-2."}]})
    if layer >= 3:
        msgs.append({"role": "assistant", "content": [{"type": "text", "text": "ok-2"}]})
        msgs.append({"role": "user", "content": [{"type": "text", "text": "small follow-up. Reply ok-3."}]})
    return msgs

def send(label, messages):
    payload = {
        "model": os.environ["KIMI_E2E_WIRE_MODEL"],
        "max_tokens": 30,
        "messages": messages,
    }
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        (os.environ.get("KIMI_CODE_BASE_URL", "https://api.kimi.com/coding/v1").rstrip("/") + "/messages"),
        data=body, headers=headers, method="POST",
    )
    start = time.time()
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            elapsed = time.time() - start
            u = data.get("usage", {})
            cache_read = max(
                int(u.get("cache_read_input_tokens", 0) or 0),
                int(u.get("cached_tokens", 0) or 0),
            )
            prompt = int(u.get("prompt_tokens", 0) or u.get("input_tokens", 0) or 0)
            new_input = int(u.get("input_tokens", 0) or max(prompt - cache_read, 0))
            print(f"[{time.strftime('%X')}] {label}: prompt={prompt} cache_read={cache_read} new_input={new_input} elapsed={elapsed:.2f}s", flush=True)
            return {"prompt": prompt, "cache_read": cache_read, "new_input": new_input}
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")[:300]
        print(f"[{time.strftime('%X')}] {label}: HTTP {e.code} {body}", flush=True)
        return None
    except Exception as e:
        print(f"[{time.strftime('%X')}] {label}: failed: {e}", flush=True)
        return None

print("--- P1 (~5K tokens) ---", flush=True)
r1 = send("P1", build(1))
time.sleep(1)
print("--- P2 (~15K tokens, ~10K delta over P1) ---", flush=True)
r2 = send("P2", build(2))
time.sleep(1)
print("--- P3 (P2 + ~50 token tail) ---", flush=True)
r3 = send("P3", build(3))

print()
print("Summary:")
def line(name, r):
    if r is None:
        return f"  {name}: failed"
    return f"  {name}: prompt={r['prompt']} cache_read={r['cache_read']} new_input={r['new_input']}"
print(line("P1", r1))
print(line("P2", r2))
print(line("P3", r3))

if r1 and r2 and r3:
    p1_aligned = (r1["prompt"] // 256) * 256
    p2_aligned = (r2["prompt"] // 256) * 256
    p2_ok = abs(r2["cache_read"] - p1_aligned) < 256
    p3_ok = abs(r3["cache_read"] - p2_aligned) < 256
    print()
    print(f"Expected P2.cache_read ~ chunk-floor(P1.prompt)={p1_aligned}, got {r2['cache_read']} ({'OK' if p2_ok else 'MISMATCH'})")
    print(f"Expected P3.cache_read ~ chunk-floor(P2.prompt)={p2_aligned}, got {r3['cache_read']} ({'OK' if p3_ok else 'MISMATCH'})")
    print()
    if p2_ok and p3_ok:
        print("Verdict: large multi-chunk deltas cache normally. Intermediate chunks are usable by the next turn.")
    elif p2_ok and not p3_ok:
        print("Verdict: P2 cached only the P1 prefix; the 10K middle did NOT cache for P3.")
    else:
        print("Verdict: chunk alignment differs from the 256-token assumption. Inspect numbers above.")
PY
  printf '\n'
}

# ---------------------------------------------------------------------------
# Test 4h: TTL Upper Bound (long-running, off by default)
# ---------------------------------------------------------------------------
# Single warmup -> long sleep -> probe. KIMI_E2E_TTL_UPPER_INTERVALS
# (comma-separated seconds, default "1800") controls which intervals run.
# Set KIMI_E2E_SKIP_TTL_UPPER=0 to enable.
ttl_upper_check() {
  if [ "${KIMI_E2E_SKIP_TTL_UPPER:-1}" = "1" ]; then
    log "=== Test 4h: TTL Upper Bound (skipped — set KIMI_E2E_SKIP_TTL_UPPER=0 to enable) ==="
    return 0
  fi

  log "=== Test 4h: TTL Upper Bound (Anthropic endpoint) ==="
  log "  intervals=${KIMI_E2E_TTL_UPPER_INTERVALS}"

  python3 - <<'PY'
import concurrent.futures
import json
import os
import time
import urllib.error
import urllib.request
import uuid

api_key = os.environ["KIMI_API_KEY"]
verbose = os.environ.get("KIMI_E2E_VERBOSE", "1") == "1"
repeat = int(os.environ.get("KIMI_E2E_CACHE_REPEAT", "2000"))
intervals = [int(x) for x in os.environ["KIMI_E2E_TTL_UPPER_INTERVALS"].split(",") if x.strip()]

filler = "This is meaningless filler text for testing Kimi TTL upper bound. " * repeat

headers = {
    "x-api-key": api_key,
    "anthropic-version": "2023-06-01",
    "content-type": "application/json",
    "User-Agent": "KimiCLI/1.44.0",
    "X-Msh-Platform": "kimi_cli",
    "X-Msh-Version": "1.44.0",
}

def send(label, text):
    payload = {
        "model": os.environ["KIMI_E2E_WIRE_MODEL"],
        "max_tokens": 50,
        "messages": [{"role": "user", "content": [{"type": "text", "text": text}]}],
    }
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        (os.environ.get("KIMI_CODE_BASE_URL", "https://api.kimi.com/coding/v1").rstrip("/") + "/messages"),
        data=body, headers=headers, method="POST",
    )
    start = time.time()
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            elapsed = time.time() - start
            u = data.get("usage", {})
            cache_read = max(
                int(u.get("cache_read_input_tokens", 0) or 0),
                int(u.get("cached_tokens", 0) or 0),
            )
            prompt = int(u.get("prompt_tokens", 0) or u.get("input_tokens", 0) or 0)
            print(f"[{time.strftime('%X')}] {label}: prompt={prompt} cache_read={cache_read} elapsed={elapsed:.2f}s", flush=True)
            return cache_read
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")[:300]
        print(f"[{time.strftime('%X')}] {label}: HTTP {e.code} {body}", flush=True)
        return -1

def run(target):
    salt = f"ttl-upper-{target}-{uuid.uuid4()}"
    text = f"variant:{salt}\n{filler}\n\nReply with only: ok"
    print(f"--- TTL upper: warm then probe at t={target}s ---", flush=True)
    send(f"warmup_{target}s", text)
    print(f"[round {target}s] sleeping {target}s...", flush=True)
    time.sleep(target)
    read = send(f"probe_{target}s", text)
    return target, read > 0

with concurrent.futures.ThreadPoolExecutor(max_workers=len(intervals)) as pool:
    futures = [pool.submit(run, t) for t in intervals]
    results = sorted([f.result() for f in concurrent.futures.as_completed(futures)])

print()
print("Results:")
for t, hit in results:
    print(f"  {t}s: {'HIT' if hit else 'MISS'}")

hits = [t for t, h in results if h]
misses = [t for t, h in results if not h]
print()
if hits and not misses:
    print(f"Verdict: TTL >= {max(hits)}s (all probes hit).")
elif misses and not hits:
    print(f"Verdict: TTL < {min(misses)}s (all probes missed).")
elif hits and misses:
    print(f"Verdict: TTL is between {max(hits)}s and {min(misses)}s.")
else:
    print("Verdict: no probes ran.")
PY
  printf '\n'
}

# ---------------------------------------------------------------------------
# Test 4i: Block Size Sweep
# ---------------------------------------------------------------------------
# Confirms the 256-token chunk-alignment finding from 4d across a range of
# prompt sizes. For each size: warm a payload, then send a 2-turn extension
# and check whether the probe's cache_read matches floor(warm.prompt / 256).
block_size_sweep_check() {
  if [ "${KIMI_E2E_SKIP_BLOCK_SIZE_SWEEP:-0}" = "1" ]; then
    log "=== Test 4i: Block Size Sweep (skipped) ==="
    return 0
  fi

  log "=== Test 4i: Block Size Sweep (Anthropic endpoint) ==="

  python3 - <<'PY'
import concurrent.futures
import json
import os
import time
import urllib.error
import urllib.request
import uuid

api_key = os.environ["KIMI_API_KEY"]
verbose = os.environ.get("KIMI_E2E_VERBOSE", "1") == "1"

repeats = [100, 200, 500, 1500, 4000]  # ~1K / 2K / 5K / 15K / 40K tokens

headers = {
    "x-api-key": api_key,
    "anthropic-version": "2023-06-01",
    "content-type": "application/json",
    "User-Agent": "KimiCLI/1.44.0",
    "X-Msh-Platform": "kimi_cli",
    "X-Msh-Version": "1.44.0",
}

def send(label, messages):
    payload = {
        "model": os.environ["KIMI_E2E_WIRE_MODEL"],
        "max_tokens": 30,
        "messages": messages,
    }
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        (os.environ.get("KIMI_CODE_BASE_URL", "https://api.kimi.com/coding/v1").rstrip("/") + "/messages"),
        data=body, headers=headers, method="POST",
    )
    start = time.time()
    try:
        with urllib.request.urlopen(req, timeout=180) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            elapsed = time.time() - start
            u = data.get("usage", {})
            cache_read = max(
                int(u.get("cache_read_input_tokens", 0) or 0),
                int(u.get("cached_tokens", 0) or 0),
            )
            prompt = int(u.get("prompt_tokens", 0) or u.get("input_tokens", 0) or 0)
            print(f"[{time.strftime('%X')}] {label}: prompt={prompt} cache_read={cache_read} elapsed={elapsed:.2f}s", flush=True)
            return {"prompt": prompt, "cache_read": cache_read}
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")[:300]
        print(f"[{time.strftime('%X')}] {label}: HTTP {e.code} {body}", flush=True)
        return None
    except Exception as e:
        print(f"[{time.strftime('%X')}] {label}: failed: {e}", flush=True)
        return None

def run(rep):
    salt = f"size-{rep}-{uuid.uuid4()}"
    base = f"variant:{salt}\n" + ("This is meaningless filler text for testing. " * rep)
    warm_msgs = [{"role": "user", "content": [{"type": "text", "text": base}]}]
    warm = send(f"size_rep{rep}_warm", warm_msgs)
    time.sleep(2)
    probe_msgs = [
        {"role": "user", "content": [{"type": "text", "text": base}]},
        {"role": "assistant", "content": [{"type": "text", "text": "ok-1"}]},
        {"role": "user", "content": [{"type": "text", "text": "follow-up. Reply ok-2."}]},
    ]
    probe = send(f"size_rep{rep}_probe", probe_msgs)
    return rep, warm, probe

with concurrent.futures.ThreadPoolExecutor(max_workers=len(repeats)) as pool:
    futures = [pool.submit(run, r) for r in repeats]
    results = sorted([f.result() for f in concurrent.futures.as_completed(futures)])

print()
print("Block size sweep:")
print(f"  {'repeat':<8}{'warm_prompt':>14}{'probe_cache_read':>20}{'aligned_256':>14}{'delta':>10}{'aligned_match':>16}")
all_ok = True
for rep, warm, probe in results:
    if warm is None or probe is None:
        print(f"  {rep:<8} FAILED")
        all_ok = False
        continue
    aligned = (warm["prompt"] // 256) * 256
    delta = probe["cache_read"] - aligned
    ok = abs(delta) < 256
    if not ok:
        all_ok = False
    print(f"  {rep:<8}{warm['prompt']:>14}{probe['cache_read']:>20}{aligned:>14}{delta:>10}{'OK' if ok else 'MISMATCH':>16}")

print()
if all_ok:
    print("Verdict: 256-token chunk alignment confirmed across all sizes.")
else:
    print("Verdict: alignment is NOT 256 for some size(s). Inspect 'delta' to estimate the actual block size.")
PY
  printf '\n'
}

# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Run this focused suite
# ---------------------------------------------------------------------------
system_tools_cache_check
large_delta_check
ttl_upper_check
block_size_sweep_check
log "E2E suite complete."
