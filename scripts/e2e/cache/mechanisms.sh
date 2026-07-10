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
# Test 4a: Cache Mechanism Isolation
# ---------------------------------------------------------------------------
# Determines which mechanism (Anthropic-style cache_control vs Kimi-native
# prompt_cache_key) actually drives cache hits on the Anthropic-compat
# /messages endpoint. Sends 4 payload variants:
#   A) cache_control only         B) prompt_cache_key only
#   C) both                       D) neither
# Each variant uses its own salted content + key so they don't share cache.
# Variants run in parallel; each does warmup -> 5s sleep -> probe.
cache_mechanism_isolation_check() {
  if [ "${KIMI_E2E_SKIP_CACHE_MATRIX:-0}" = "1" ]; then
    log "=== Test 4a: Cache Mechanism Isolation (skipped) ==="
    return 0
  fi

  log "=== Test 4a: Cache Mechanism Isolation (Anthropic endpoint) ==="

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

def build_payload(salt, use_cache_control, prompt_cache_key):
    text = f"variant:{salt}\n{filler}\n\nReply with only: ok"
    block = {"type": "text", "text": text}
    if use_cache_control:
        block["cache_control"] = {"type": "ephemeral"}
    payload = {
        "model": os.environ["KIMI_E2E_WIRE_MODEL"],
        "max_tokens": 50,
        "messages": [{"role": "user", "content": [block]}],
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

def run_variant(name, use_cc, use_key):
    salt = f"{name}-{uuid.uuid4()}"
    pcache_key = f"isolation-{salt}" if use_key else None
    payload = build_payload(salt, use_cc, pcache_key)
    print(f"--- Variant {name} (cache_control={use_cc}, prompt_cache_key={'set' if use_key else 'unset'}) ---", flush=True)
    send(f"warmup_{name}", payload)
    time.sleep(5)
    cache_read = send(f"probe_{name}", payload)
    return name, cache_read

variants = [
    ("A_cc_only",  True,  False),
    ("B_key_only", False, True),
    ("C_both",     True,  True),
    ("D_neither",  False, False),
]

with concurrent.futures.ThreadPoolExecutor(max_workers=len(variants)) as pool:
    futures = [pool.submit(run_variant, *v) for v in variants]
    results = [f.result() for f in concurrent.futures.as_completed(futures)]

results.sort()
print()
print("Variant matrix (probe cache_read_input_tokens):")
hits = set()
for name, read in results:
    hit = read > 0
    if hit:
        hits.add(name)
    print(f"  {name}: {'HIT' if hit else 'MISS'} (cache_read={read})")

print()
if "A_cc_only" in hits and "B_key_only" not in hits:
    print("Conclusion: Kimi /messages honors cache_control. prompt_cache_key alone does NOT cache.")
elif "B_key_only" in hits and "A_cc_only" not in hits:
    print("Conclusion: Kimi /messages honors prompt_cache_key. cache_control alone does NOT cache.")
elif "A_cc_only" in hits and "B_key_only" in hits:
    print("Conclusion: Both mechanisms cache independently on Kimi /messages.")
elif "C_both" in hits and "A_cc_only" not in hits and "B_key_only" not in hits:
    print("Conclusion: Cache hit requires BOTH mechanisms set together.")
elif not hits:
    print("Conclusion: No cache hits across all 4 variants. Cache disabled, or warmup->probe gap too short.")
else:
    print(f"Conclusion: inconclusive. Hits = {sorted(hits)}")
PY
  printf '\n'
}

# ---------------------------------------------------------------------------
# Test 4b: Dual Cache-Breakpoint vs Single Cache-Breakpoint
# ---------------------------------------------------------------------------
# Multi-turn conversation containing assistant tool_use. Compares two marker
# strategies:
#   single: cache_control only on the last block of the last user message
#   dual:   cache_control on the last assistant tool_use AND the last user
#
# Each variant warms with a turn-N payload, sleeps 5s, then probes with
# turn-N+1 (turn-N plus one more assistant+tool_use round and one more user
# message). Measures cache_read_input_tokens on the probe. If dual reads
# substantially more than single, the optimization claimed by
# pi-better-messages-cache (PR #1737) applies to Kimi.
dual_breakpoint_check() {
  if [ "${KIMI_E2E_SKIP_DUAL_BREAKPOINT:-0}" = "1" ]; then
    log "=== Test 4b: Dual vs Single Cache-Breakpoint (skipped) ==="
    return 0
  fi

  log "=== Test 4b: Dual vs Single Cache-Breakpoint (Anthropic endpoint) ==="

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

# Tool declared in every request so the assistant tool_use history is
# self-consistent. Without this, some endpoints reject historical tool_use
# blocks whose tool name isn't in the current request's tools list.
TOOLS = [{
    "name": "Read",
    "description": "Read a file from the filesystem.",
    "input_schema": {
        "type": "object",
        "properties": {"path": {"type": "string"}},
        "required": ["path"],
    },
}]

def build_turn_n(salt):
    big_user_text = f"variant:{salt}\n{filler}\n\nPlease read package.json and report the version."
    return [
        {"role": "user", "content": [
            {"type": "text", "text": big_user_text},
        ]},
        {"role": "assistant", "content": [
            {"type": "text", "text": "I'll read package.json."},
            {"type": "tool_use", "id": f"toolu_{salt}_1", "name": "Read",
             "input": {"path": "package.json"}},
        ]},
        {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": f"toolu_{salt}_1",
             "content": '{\n  "name": "demo",\n  "version": "1.0.0"\n}'},
            {"type": "text", "text": "thanks, now wait for the next question"},
        ]},
    ]

def build_turn_n_plus_1(salt):
    msgs = build_turn_n(salt)
    msgs.append({"role": "assistant", "content": [
        {"type": "text", "text": "Acknowledged. What's next?"},
        {"type": "tool_use", "id": f"toolu_{salt}_2", "name": "Read",
         "input": {"path": "README.md"}},
    ]})
    msgs.append({"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": f"toolu_{salt}_2",
         "content": "# Demo\n\nThis is a demo README for cache testing."},
        {"type": "text", "text": "summarize both files in one sentence"},
    ]})
    return msgs

def apply_single_marker(messages):
    """Mark only the last block of the last (user) message."""
    last_msg = messages[-1]
    last_msg["content"][-1]["cache_control"] = {"type": "ephemeral"}

def apply_dual_marker(messages):
    """Mark last assistant tool_use + last user block (pi-better-messages-cache strategy)."""
    apply_single_marker(messages)
    for msg in reversed(messages):
        if msg["role"] == "assistant":
            for block in reversed(msg["content"]):
                if block.get("type") == "tool_use":
                    block["cache_control"] = {"type": "ephemeral"}
                    return
            return

def send(label, messages):
    payload = {
        "model": os.environ["KIMI_E2E_WIRE_MODEL"],
        "max_tokens": 100,
        "tools": TOOLS,
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
            print(f"[{time.strftime('%X')}] {label}: input={input_tokens} cache_read={cache_read} cache_create={cache_create} elapsed={elapsed:.2f}s", flush=True)
            if verbose:
                print(f"  usage={json.dumps(u, ensure_ascii=False)}", flush=True)
            return cache_read, input_tokens
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")[:300]
        print(f"[{time.strftime('%X')}] {label}: HTTP {e.code} {body}", flush=True)
        return -1, -1
    except Exception as e:
        print(f"[{time.strftime('%X')}] {label}: failed: {e}", flush=True)
        return -1, -1

def run_variant(name, marker_fn):
    salt = f"{name}-{uuid.uuid4()}"
    turn_n = build_turn_n(salt)
    marker_fn(turn_n)
    print(f"--- Variant {name}: warm turn N ---", flush=True)
    send(f"{name}_warm_turn_N", turn_n)
    time.sleep(5)

    turn_n1 = build_turn_n_plus_1(salt)
    marker_fn(turn_n1)
    print(f"--- Variant {name}: probe turn N+1 ---", flush=True)
    cache_read, input_tokens = send(f"{name}_probe_turn_N+1", turn_n1)
    return name, cache_read, input_tokens

variants = [
    ("single", apply_single_marker),
    ("dual",   apply_dual_marker),
]

with concurrent.futures.ThreadPoolExecutor(max_workers=len(variants)) as pool:
    futures = [pool.submit(run_variant, *v) for v in variants]
    results = [f.result() for f in concurrent.futures.as_completed(futures)]

results.sort()
print()
print("Turn N+1 probe results:")
data = {}
for name, cache_read, input_tokens in results:
    pct = (cache_read / input_tokens * 100.0) if input_tokens > 0 else 0.0
    data[name] = (cache_read, input_tokens, pct)
    print(f"  {name}: cache_read={cache_read}/{input_tokens} ({pct:.1f}%)")

print()
single = data.get("single")
dual = data.get("dual")
if single and dual and single[0] >= 0 and dual[0] >= 0:
    if dual[0] > single[0] * 1.05:
        delta = dual[0] - single[0]
        print(f"Conclusion: Dual marker reads MORE cache than single (+{delta} tokens, {dual[0]} vs {single[0]}). Worth adopting.")
    elif single[0] > dual[0] * 1.05:
        delta = single[0] - dual[0]
        print(f"Conclusion: Single marker reads MORE cache than dual (+{delta} tokens, {single[0]} vs {dual[0]}). Unexpected.")
    elif single[0] == 0 and dual[0] == 0:
        print("Conclusion: Neither variant read cache. Either the warm->probe gap is too short, or cache_control on multi-turn payloads is not honored.")
    else:
        print(f"Conclusion: Single and dual read similar amounts ({single[0]} vs {dual[0]}). No measurable benefit from dual marking on this workload.")
else:
    print("Conclusion: One or both variants failed; inconclusive.")
PY
  printf '\n'
}

# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Run this focused suite
# ---------------------------------------------------------------------------
cache_mechanism_isolation_check
dual_breakpoint_check
log "E2E suite complete."
