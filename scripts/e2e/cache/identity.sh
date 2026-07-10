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
# Test 4c: Cache Key Semantics (multi-agent collision check)
# ---------------------------------------------------------------------------
# Test 4a established that all 4 variants (key/no-key, cc/no-cc) HIT, but those
# variants used distinct content, so they couldn't collide by construction.
# 4c directly attacks the question: does prompt_cache_key participate in cache
# identity, or is it cosmetic?
#
# V1 (collision): same prompt_cache_key, two different contents.
#   warm X with key K -> warm Y with key K -> probe X with key K.
#   - X probe HIT  => key is ignored (cache is content-only, agents safe)
#   - X probe MISS => Y evicted X (key-keyed slot, agents collide)
#
# V2 (segregation): same content, two different keys.
#   warm with K1 -> probe with K2.
#   - probe HIT  => key is fully ignored
#   - probe MISS => key partitions cache (cross-key isolation)
cache_key_semantics_check() {
  if [ "${KIMI_E2E_SKIP_CACHE_KEY_SEMANTICS:-0}" = "1" ]; then
    log "=== Test 4c: Cache Key Semantics (skipped) ==="
    return 0
  fi

  log "=== Test 4c: Cache Key Semantics (Anthropic endpoint) ==="

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

filler = "This is meaningless filler text for testing Kimi Prompt Cache. " * repeat

headers = {
    "x-api-key": api_key,
    "anthropic-version": "2023-06-01",
    "content-type": "application/json",
    "User-Agent": "KimiCLI/1.44.0",
    "X-Msh-Platform": "kimi_cli",
    "X-Msh-Version": "1.44.0",
}

def build_payload(salt, prompt_cache_key=None):
    text = f"semantics:{salt}\n{filler}\n\nReply with only: ok"
    payload = {
        "model": os.environ["KIMI_E2E_WIRE_MODEL"],
        "max_tokens": 50,
        "messages": [{"role": "user", "content": [{"type": "text", "text": text}]}],
    }
    if prompt_cache_key:
        payload["prompt_cache_key"] = prompt_cache_key
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
            cache_create = int(u.get("cache_creation_input_tokens", 0) or 0)
            input_tokens = int(u.get("input_tokens", 0) or 0)
            print(f"[{time.strftime('%X')}] {label}: input={input_tokens} cache_read={cache_read} cache_create={cache_create} elapsed={elapsed:.2f}s", flush=True)
            if verbose:
                print(f"  usage={json.dumps(u, ensure_ascii=False)}", flush=True)
            return cache_read
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")[:300]
        print(f"[{time.strftime('%X')}] {label}: HTTP {e.code} {body}", flush=True)
        return -1
    except Exception as e:
        print(f"[{time.strftime('%X')}] {label}: failed: {e}", flush=True)
        return -1

def run_v1_collision():
    shared_key = f"v1-shared-{uuid.uuid4()}"
    salt_x = f"v1x-{uuid.uuid4()}"
    salt_y = f"v1y-{uuid.uuid4()}"
    px = build_payload(salt_x, shared_key)
    py = build_payload(salt_y, shared_key)

    print(f"--- V1 collision: shared_key={shared_key} ---", flush=True)
    send("v1_warm_X", px)
    send("v1_warm_Y", py)
    time.sleep(3)
    read_x = send("v1_probe_X", px)
    read_y = send("v1_probe_Y", py)
    return read_x, read_y

def run_v2_segregation():
    salt = f"v2-{uuid.uuid4()}"
    k1 = f"v2-k1-{uuid.uuid4()}"
    k2 = f"v2-k2-{uuid.uuid4()}"
    p1 = build_payload(salt, k1)
    p2 = build_payload(salt, k2)  # IDENTICAL content, different key

    print(f"--- V2 segregation: same content, K1={k1} K2={k2} ---", flush=True)
    send("v2_warm_with_K1", p1)
    time.sleep(3)
    read_k2 = send("v2_probe_with_K2", p2)
    return read_k2

with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    fut_v1 = pool.submit(run_v1_collision)
    fut_v2 = pool.submit(run_v2_segregation)
    read_x, read_y = fut_v1.result()
    read_k2 = fut_v2.result()

v1_x_hit = read_x > 0
v1_y_hit = read_y > 0
v2_hit = read_k2 > 0

print()
print("Results:")
print(f"  V1.X probe (warmed first, same key as Y): {'HIT' if v1_x_hit else 'MISS'} (cache_read={read_x})")
print(f"  V1.Y probe (warmed second, same key as X): {'HIT' if v1_y_hit else 'MISS'} (cache_read={read_y})")
print(f"  V2 probe (same content, different key from warmup): {'HIT' if v2_hit else 'MISS'} (cache_read={read_k2})")

print()
if v1_x_hit and v1_y_hit and v2_hit:
    print("Verdict: prompt_cache_key is FULLY IGNORED. Cache identity = content hash only.")
    print("  - Two agents with different content cannot collide via key.")
    print("  - Two agents with same content (overlapping prefix) share cache => free hit.")
elif (not v1_x_hit) and v1_y_hit:
    print("Verdict: prompt_cache_key enforces SINGLE-SLOT EVICTION. Y evicted X.")
    print("  - WARNING: two agents sharing a key will trash each other's cache.")
elif v1_x_hit and v1_y_hit and not v2_hit:
    print("Verdict: prompt_cache_key PARTITIONS cache (segregation, no eviction).")
    print("  - Different agents get different cache spaces; same key required to hit.")
elif (not v1_x_hit) and (not v1_y_hit) and (not v2_hit):
    print("Verdict: no cache hits at all. Either the warmup gap is too short, or cache is disabled.")
else:
    print(f"Verdict: unexpected combination. v1_x={v1_x_hit} v1_y={v1_y_hit} v2={v2_hit}")
    print("  Need follow-up investigation.")
PY
  printf '\n'
}

# ---------------------------------------------------------------------------
# Test 4d: Cache Chain Growth, Persistence, and Divergent Branch
# ---------------------------------------------------------------------------
# 4a/4b/4c established that markers are decorative and cache identity is
# content-hash. 4d directly tests the multi-turn dynamics that matter for a
# coding agent:
#
# Phase 1 (chain growth): send turns 1..5 of a growing conversation. Each turn
#   appends ~50 new tokens to a ~10K-token base. Expectation: turn N's
#   cache_read >= turn N-1's prompt_tokens (delta-only processing).
#
# Phase 2 (persistence): after the chain, re-send earlier turns standalone.
#   Expectation: HIT (older prefixes still readable from cache).
#
# Phase 3 (divergent branch): build a 5-turn variant that branches off at
#   turn 4 (turns 1..3 identical to main, turns 4..5 differ). Expectation:
#   cache_read ~= main turn 3's prompt_tokens (shared prefix is reused).
#
# Also reports cumulative cache_creation_input_tokens (expected: 0 — Kimi
# does not surface cache writes).
cache_chain_check() {
  if [ "${KIMI_E2E_SKIP_CACHE_CHAIN:-0}" = "1" ]; then
    log "=== Test 4d: Cache Chain / Persistence / Branch (skipped) ==="
    return 0
  fi

  log "=== Test 4d: Cache Chain / Persistence / Branch (Anthropic endpoint) ==="

  python3 - <<'PY'
import json
import os
import sys
import time
import urllib.error
import urllib.request
import uuid

api_key = os.environ["KIMI_API_KEY"]
verbose = os.environ.get("KIMI_E2E_VERBOSE", "1") == "1"

filler = "This is meaningless filler text for testing Kimi Prompt Cache chain growth. " * 800

headers = {
    "x-api-key": api_key,
    "anthropic-version": "2023-06-01",
    "content-type": "application/json",
    "User-Agent": "KimiCLI/1.44.0",
    "X-Msh-Platform": "kimi_cli",
    "X-Msh-Version": "1.44.0",
}

salt = f"chain-{uuid.uuid4()}"
base_user_text = f"chain-base:{salt}\n{filler}\n\nWe'll have a multi-turn chat. Reply ok-1."

def build_main(turn_n):
    """Linear chain through `turn_n` turns (turn 1 = base only, each new turn
    appends one assistant ack + one user follow-up)."""
    msgs = [{"role": "user", "content": [{"type": "text", "text": base_user_text}]}]
    for i in range(1, turn_n):
        msgs.append({"role": "assistant", "content": [{"type": "text", "text": f"ok-{i}"}]})
        msgs.append({"role": "user", "content": [{"type": "text", "text": f"Question {i+1}. Reply ok-{i+1}."}]})
    return msgs

def build_branch(turn_n, branch_from):
    """Same as build_main, but everything from turn `branch_from` onward gets
    a 'B' suffix so the content diverges past that point."""
    msgs = [{"role": "user", "content": [{"type": "text", "text": base_user_text}]}]
    for i in range(1, turn_n):
        lbl = "B" if i >= branch_from else ""
        msgs.append({"role": "assistant", "content": [{"type": "text", "text": f"ok-{i}{lbl}"}]})
        msgs.append({"role": "user", "content": [{"type": "text", "text": f"Question {i+1}{lbl}. Reply ok-{i+1}{lbl}."}]})
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
            cache_create = int(u.get("cache_creation_input_tokens", 0) or 0)
            input_tokens = int(u.get("input_tokens", 0) or 0)
            prompt_tokens = int(u.get("prompt_tokens", 0) or 0)
            print(f"[{time.strftime('%X')}] {label}: prompt={prompt_tokens} new_input={input_tokens} cache_read={cache_read} cache_create={cache_create} elapsed={elapsed:.2f}s", flush=True)
            return {
                "new_input": input_tokens,
                "prompt": prompt_tokens,
                "cache_read": cache_read,
                "cache_create": cache_create,
            }
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")[:300]
        print(f"[{time.strftime('%X')}] {label}: HTTP {e.code} {body}", flush=True)
        return None
    except Exception as e:
        print(f"[{time.strftime('%X')}] {label}: failed: {e}", flush=True)
        return None

# Phase 1: linear chain growth
print("--- Phase 1: linear chain growth (5 turns) ---", flush=True)
chain = []
for n in range(1, 6):
    r = send(f"chain_turn_{n}", build_main(n))
    if r is None:
        print("Phase 1 aborted (HTTP error).", flush=True)
        sys.exit(0)
    chain.append((n, r))
    time.sleep(1)

# Phase 2: re-probe earlier turns
print("--- Phase 2: re-probe earlier turns ---", flush=True)
reprobes = {}
for n in [1, 3]:
    r = send(f"reprobe_turn_{n}", build_main(n))
    if r is not None:
        reprobes[n] = r
    time.sleep(1)

# Phase 3: divergent branch
print("--- Phase 3: divergent branch from turn 4 ---", flush=True)
branch = send("branch_from_turn_4", build_branch(5, branch_from=4))

# ---- Summary tables ----
print()
print("Phase 1 chain growth:")
print(f"  {'turn':<6}{'prompt':>10}{'cache_read':>14}{'new_input':>12}{'cache_create':>14}")
for n, r in chain:
    print(f"  {n:<6}{r['prompt']:>10}{r['cache_read']:>14}{r['new_input']:>12}{r['cache_create']:>14}")

print()
print("Phase 2 re-probe:")
for n, r in reprobes.items():
    print(f"  turn {n}: prompt={r['prompt']} cache_read={r['cache_read']} ({'HIT' if r['cache_read'] > 0 else 'MISS'})")

print()
print("Phase 3 branch:")
if branch:
    expected_shared = chain[2][1]["prompt"]  # main turn 3
    ratio = (branch["cache_read"] / expected_shared * 100.0) if expected_shared > 0 else 0.0
    print(f"  branch from turn 4: prompt={branch['prompt']} cache_read={branch['cache_read']}")
    print(f"  (main turn 3 prompt was {expected_shared}; cache_read / main_turn_3 = {ratio:.1f}%)")
else:
    print("  branch request failed")

# ---- Verdicts ----
print()
# V1: chain growth
chain_ok = chain[0][1]["cache_read"] == 0  # turn 1 must miss (first send)
for i in range(1, len(chain)):
    prev_prompt = chain[i-1][1]["prompt"]
    this_cache_read = chain[i][1]["cache_read"]
    if this_cache_read < prev_prompt * 0.95:
        chain_ok = False
        print(f"  [chain growth FAIL] turn {chain[i][0]}: cache_read={this_cache_read} < 95% of prev_prompt={prev_prompt}")
if chain_ok:
    print("Verdict 1: CHAIN GROWTH WORKS. Each new turn reads the previous prefix; only the delta is processed.")
else:
    print("Verdict 1: chain growth broken (see flags above).")

# V2: persistence
persistence_ok = all(r["cache_read"] > 0 for r in reprobes.values())
if persistence_ok:
    print("Verdict 2: OLD PREFIXES PERSIST. Re-sending earlier turns still HITs after newer turns were cached.")
else:
    miss = [n for n, r in reprobes.items() if r["cache_read"] == 0]
    print(f"Verdict 2: older prefixes evicted for turn(s) {miss}.")

# V3: divergent branch
if branch and branch["cache_read"] > 0:
    expected = chain[2][1]["prompt"]
    ratio = branch["cache_read"] / expected if expected > 0 else 0
    if 0.95 <= ratio <= 1.05:
        print(f"Verdict 3: BRANCH REUSES SHARED PREFIX. cache_read ({branch['cache_read']}) ~= main turn 3 prompt ({expected}).")
    elif ratio > 0.5:
        print(f"Verdict 3: branch reused PARTIAL shared prefix. cache_read={branch['cache_read']}, ratio={ratio:.1%} of main turn 3.")
    else:
        print(f"Verdict 3: branch cache_read={branch['cache_read']} is below expected shared prefix size {expected}.")
else:
    print("Verdict 3: branch did NOT hit cache. Either Kimi only caches exact-final-message payloads, or test failed.")

# V4: cache_creation surface area
total_create = sum(r["cache_create"] for _, r in chain) \
             + sum(r["cache_create"] for r in reprobes.values()) \
             + (branch["cache_create"] if branch else 0)
if total_create == 0:
    print("Verdict 4: cache_creation_input_tokens is 0 across ALL requests. Kimi does not surface cache writes (no visible per-write cost).")
else:
    print(f"Verdict 4: cache_creation_input_tokens total = {total_create} across all requests.")
PY
  printf '\n'
}

# ---------------------------------------------------------------------------
# Test 4e: Cross-Protocol Cache Share
# ---------------------------------------------------------------------------
# Warm via one protocol, probe via the other with content that maps to the
# same underlying tokens. Two directions:
#   A) Anthropic /messages -> OpenAI /chat/completions
#   B) OpenAI /chat/completions -> Anthropic /messages
# If both probes HIT, the cache is keyed below the protocol layer and
# KIMI_CODE_PROTOCOL switching does not invalidate.
cross_protocol_cache_check() {
  if [ "${KIMI_E2E_SKIP_CROSS_PROTOCOL:-0}" = "1" ]; then
    log "=== Test 4e: Cross-Protocol Cache Share (skipped) ==="
    return 0
  fi

  log "=== Test 4e: Cross-Protocol Cache Share ==="

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

filler = "This is meaningless filler text for testing Kimi Prompt Cache. " * repeat

ANTHROPIC_HEADERS = {
    "x-api-key": api_key,
    "anthropic-version": "2023-06-01",
    "content-type": "application/json",
    "User-Agent": "KimiCLI/1.44.0",
    "X-Msh-Platform": "kimi_cli",
    "X-Msh-Version": "1.44.0",
}
OPENAI_HEADERS = {
    "Authorization": f"Bearer {api_key}",
    "content-type": "application/json",
    "User-Agent": "KimiCLI/1.44.0",
    "X-Msh-Platform": "kimi_cli",
    "X-Msh-Version": "1.44.0",
}

def _post(label, url, payload, headers):
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    start = time.time()
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            elapsed = time.time() - start
            u = data.get("usage", {})
            details = u.get("prompt_tokens_details") or {}
            cache_read = max(
                int(u.get("cache_read_input_tokens", 0) or 0),
                int(u.get("cached_tokens", 0) or 0),
                int(details.get("cached_tokens", 0) or 0),
            )
            prompt = int(u.get("prompt_tokens", 0) or u.get("input_tokens", 0) or 0)
            new_input = int(u.get("input_tokens", 0) or max(prompt - cache_read, 0))
            print(f"[{time.strftime('%X')}] {label}: prompt={prompt} cache_read={cache_read} new_input={new_input} elapsed={elapsed:.2f}s", flush=True)
            if verbose:
                print(f"  usage={json.dumps(u, ensure_ascii=False)}", flush=True)
            return cache_read
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")[:300]
        print(f"[{time.strftime('%X')}] {label}: HTTP {e.code} {body}", flush=True)
        return -1
    except Exception as e:
        print(f"[{time.strftime('%X')}] {label}: failed: {e}", flush=True)
        return -1

def send_anthropic(label, text):
    payload = {
        "model": os.environ["KIMI_E2E_WIRE_MODEL"],
        "max_tokens": 50,
        "messages": [{"role": "user", "content": [{"type": "text", "text": text}]}],
    }
    return _post(label, (os.environ.get("KIMI_CODE_BASE_URL", "https://api.kimi.com/coding/v1").rstrip("/") + "/messages"), payload, ANTHROPIC_HEADERS)

def send_openai(label, text):
    payload = {
        "model": os.environ["KIMI_E2E_WIRE_MODEL"],
        "max_tokens": 50,
        "messages": [{"role": "user", "content": text}],
    }
    return _post(label, (os.environ.get("KIMI_CODE_BASE_URL", "https://api.kimi.com/coding/v1").rstrip("/") + "/chat/completions"), payload, OPENAI_HEADERS)

# Direction A: warm anthropic, probe openai
salt_a = f"xprotoA-{uuid.uuid4()}"
text_a = f"variant:{salt_a}\n{filler}\n\nReply with only: ok"
print("--- Direction A: warm /messages -> probe /chat/completions ---", flush=True)
send_anthropic("A_warm_anthropic", text_a)
time.sleep(3)
read_a = send_openai("A_probe_openai", text_a)

# Direction B: warm openai, probe anthropic
salt_b = f"xprotoB-{uuid.uuid4()}"
text_b = f"variant:{salt_b}\n{filler}\n\nReply with only: ok"
print("--- Direction B: warm /chat/completions -> probe /messages ---", flush=True)
send_openai("B_warm_openai", text_b)
time.sleep(3)
read_b = send_anthropic("B_probe_anthropic", text_b)

# Thresholds: ignore tiny system-level cache hits (a few dozen tokens) — we
# only care if the bulk of the filler-laden prompt comes from cache.
threshold = 1000
a_hit = read_a > threshold
b_hit = read_b > threshold

print()
print(f"Direction A (anthropic -> openai): cache_read={read_a} ({'HIT' if a_hit else 'MISS'})")
print(f"Direction B (openai -> anthropic): cache_read={read_b} ({'HIT' if b_hit else 'MISS'})")
print()
if a_hit and b_hit:
    print("Verdict: cache is SHARED across protocols. KIMI_CODE_PROTOCOL switching does NOT invalidate cache.")
elif (not a_hit) and (not b_hit):
    print("Verdict: caches are SEPARATE per protocol. Switching KIMI_CODE_PROTOCOL forces a cold prefix.")
else:
    print(f"Verdict: asymmetric. anthropic->openai={'HIT' if a_hit else 'MISS'}, openai->anthropic={'HIT' if b_hit else 'MISS'}.")
PY
  printf '\n'
}

# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Run this focused suite
# ---------------------------------------------------------------------------
cache_key_semantics_check
cache_chain_check
cross_protocol_cache_check
log "E2E suite complete."
