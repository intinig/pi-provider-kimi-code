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
# Test 4j: Tools-Only Change
# ---------------------------------------------------------------------------
# Same messages and system, but the `tools` array differs between warm and
# probe. Three scenarios:
#   J0 baseline: identical tools -> full HIT expected
#   J1 different tool content
#   J2 add tool on probe (warm had no tools)
tools_change_cache_check() {
  if [ "${KIMI_E2E_SKIP_TOOLS_CHANGE:-0}" = "1" ]; then
    log "=== Test 4j: Tools-Only Change (skipped) ==="
    return 0
  fi

  log "=== Test 4j: Tools-Only Change (Anthropic endpoint) ==="

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

filler = "This is meaningless filler text for testing tools cache impact. " * repeat

headers = {
    "x-api-key": api_key,
    "anthropic-version": "2023-06-01",
    "content-type": "application/json",
    "User-Agent": "KimiCLI/1.44.0",
    "X-Msh-Platform": "kimi_cli",
    "X-Msh-Version": "1.44.0",
}

TOOL_READ = {
    "name": "Read",
    "description": "Read a file from the filesystem.",
    "input_schema": {
        "type": "object",
        "properties": {"path": {"type": "string"}},
        "required": ["path"],
    },
}
TOOL_WRITE = {
    "name": "Write",
    "description": "Write a file to disk.",
    "input_schema": {
        "type": "object",
        "properties": {"path": {"type": "string"}, "content": {"type": "string"}},
        "required": ["path", "content"],
    },
}

def build_payload(salt, tools=None):
    text = f"variant:{salt}\n{filler}\n\nReply with only: ok"
    p = {
        "model": os.environ["KIMI_E2E_WIRE_MODEL"],
        "max_tokens": 50,
        "messages": [{"role": "user", "content": [{"type": "text", "text": text}]}],
    }
    if tools is not None:
        p["tools"] = tools
    return p

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

# J0 baseline: identical tools
salt0 = f"J0-{uuid.uuid4()}"
p0 = build_payload(salt0, tools=[TOOL_READ])
j0_read, j0_prompt = run("J0_baseline", p0, p0)

# J1: different tool content (Read -> Write)
salt1 = f"J1-{uuid.uuid4()}"
p1a = build_payload(salt1, tools=[TOOL_READ])
p1b = build_payload(salt1, tools=[TOOL_WRITE])
j1_read, j1_prompt = run("J1_tool_swapped", p1a, p1b)

# J2: add tool on probe (warm had no tools)
salt2 = f"J2-{uuid.uuid4()}"
p2a = build_payload(salt2)
p2b = build_payload(salt2, tools=[TOOL_READ])
j2_read, j2_prompt = run("J2_tool_added", p2a, p2b)

print()
print("Results:")
print(f"  J0 baseline:         cache_read={j0_read} / prompt={j0_prompt}")
print(f"  J1 tool swapped:     cache_read={j1_read} / prompt={j1_prompt}")
print(f"  J2 tool added:       cache_read={j2_read} / prompt={j2_prompt}")

print()
if j0_read > 0:
    r1 = (j1_read / j0_read) if (j1_read >= 0 and j0_read > 0) else 0
    r2 = (j2_read / j0_read) if (j2_read >= 0 and j0_read > 0) else 0
    print(f"Ratios vs J0 baseline: J1={r1:.1%}  J2={r2:.1%}")
    if r1 > 0.9 and r2 > 0.9:
        print("Verdict: tools cache INDEPENDENTLY from messages. Changing the tools array does not invalidate the messages cache.")
    elif r1 < 0.2 and r2 < 0.2:
        print("Verdict: tools are part of the PREFIX. Changing them invalidates cache.")
    else:
        print("Verdict: mixed. Adding vs swapping tools behaves differently.")
else:
    print("Verdict: J0 baseline failed; cannot interpret.")
PY
  printf '\n'
}

# ---------------------------------------------------------------------------
# Test 4k: Small Prompt / Chunk Boundary Sweep
# ---------------------------------------------------------------------------
# For tiny prompts, prefix-extension hits should stay at 0 until the prompt
# crosses the first 256-token chunk. Exact re-sends should still read the full
# prompt from cache.
small_boundary_cache_check() {
  if [ "${KIMI_E2E_SKIP_SMALL_BOUNDARY:-0}" = "1" ]; then
    log "=== Test 4k: Small Prompt / Chunk Boundary Sweep (skipped) ==="
    return 0
  fi

  log "=== Test 4k: Small Prompt / Chunk Boundary Sweep (Anthropic endpoint) ==="

  python3 - <<'PY'
import json
import os
import time
import urllib.error
import urllib.request
import uuid

api_key = os.environ["KIMI_API_KEY"]
base_url = os.environ.get("KIMI_CODE_BASE_URL", "https://api.kimi.com/coding/v1").rstrip("/")

headers = {
    "x-api-key": api_key,
    "anthropic-version": "2023-06-01",
    "content-type": "application/json",
    "User-Agent": "KimiCLI/1.44.0",
    "X-Msh-Platform": "kimi_cli",
    "X-Msh-Version": "1.44.0",
}

repeats = [1, 5, 10, 20, 40, 80]

def cache_read_from_usage(u):
    return max(int(u.get("cache_read_input_tokens", 0) or 0), int(u.get("cached_tokens", 0) or 0))

def send(label, messages):
    payload = {"model": os.environ["KIMI_E2E_WIRE_MODEL"], "max_tokens": 20, "messages": messages}
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(f"{base_url}/messages", data=body, headers=headers, method="POST")
    start = time.time()
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            elapsed = time.time() - start
            u = data.get("usage", {})
            prompt = int(u.get("prompt_tokens", 0) or u.get("input_tokens", 0) or 0)
            read = cache_read_from_usage(u)
            print(f"[{time.strftime('%X')}] {label}: prompt={prompt} cache_read={read} elapsed={elapsed:.2f}s", flush=True)
            return {"prompt": prompt, "cache_read": read}
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")[:300]
        print(f"[{time.strftime('%X')}] {label}: HTTP {e.code} {body}", flush=True)
        return None
    except Exception as e:
        print(f"[{time.strftime('%X')}] {label}: failed: {e}", flush=True)
        return None

def build_base(salt, rep):
    text = f"small-boundary:{salt}\n" + ("boundary token padding. " * rep) + "\nReply ok."
    return [{"role": "user", "content": [{"type": "text", "text": text}]}]

def build_extended(salt, rep):
    msgs = build_base(salt, rep)
    msgs.append({"role": "assistant", "content": [{"type": "text", "text": "ok"}]})
    msgs.append({"role": "user", "content": [{"type": "text", "text": "follow-up. Reply ok again."}]})
    return msgs

rows = []
for rep in repeats:
    salt = f"small-{rep}-{uuid.uuid4()}"
    warm = send(f"rep{rep}_warm", build_base(salt, rep))
    time.sleep(1)
    exact = send(f"rep{rep}_exact", build_base(salt, rep))
    time.sleep(1)
    extended = send(f"rep{rep}_extended", build_extended(salt, rep))
    rows.append((rep, warm, exact, extended))

print()
print("Small boundary results:")
print(f"  {'repeat':<8}{'warm_prompt':>14}{'exact_read':>14}{'extended_read':>16}{'floor256':>10}{'prefix_match':>14}")
all_exact = True
all_prefix = True
for rep, warm, exact, extended in rows:
    if warm is None or exact is None or extended is None:
        print(f"  {rep:<8} FAILED")
        all_exact = False
        all_prefix = False
        continue
    floor256 = (warm["prompt"] // 256) * 256
    exact_ok = exact["cache_read"] >= warm["prompt"] * 0.95
    prefix_ok = abs(extended["cache_read"] - floor256) < 256
    all_exact = all_exact and exact_ok
    all_prefix = all_prefix and prefix_ok
    print(f"  {rep:<8}{warm['prompt']:>14}{exact['cache_read']:>14}{extended['cache_read']:>16}{floor256:>10}{'OK' if prefix_ok else 'MISMATCH':>14}")

print()
if all_exact:
    print("Verdict 1: exact re-sends cache fully, including small prompts.")
else:
    print("Verdict 1: at least one exact re-send did not read the full prompt.")
if all_prefix:
    print("Verdict 2: prefix-extension reads follow 256-token floors across the small-prompt boundary.")
else:
    print("Verdict 2: small-prompt prefix-extension alignment differs from the 256-token assumption.")
PY
  printf '\n'
}

# ---------------------------------------------------------------------------
# Test 4l: OpenAI Endpoint Cache Boundaries
# ---------------------------------------------------------------------------
# Formalizes the OpenAI-compatible endpoint checks: exact re-send, prefix
# extension, and a short warm->probe delay using prompt_tokens_details.
openai_cache_boundary_check() {
  if [ "${KIMI_E2E_SKIP_OPENAI_CACHE_BOUNDARY:-0}" = "1" ]; then
    log "=== Test 4l: OpenAI Endpoint Cache Boundaries (skipped) ==="
    return 0
  fi

  log "=== Test 4l: OpenAI Endpoint Cache Boundaries ==="

  python3 - <<'PY'
import json
import os
import time
import urllib.error
import urllib.request
import uuid

api_key = os.environ["KIMI_API_KEY"]
base_url = os.environ.get("KIMI_CODE_BASE_URL", "https://api.kimi.com/coding/v1").rstrip("/")
repeat = int(os.environ.get("KIMI_E2E_CACHE_REPEAT", "2000"))

headers = {
    "Authorization": f"Bearer {api_key}",
    "content-type": "application/json",
    "User-Agent": "KimiCLI/1.44.0",
    "X-Msh-Platform": "kimi_cli",
    "X-Msh-Version": "1.44.0",
}

def cache_read_from_usage(u):
    details = u.get("prompt_tokens_details") or {}
    return max(
        int(u.get("cache_read_input_tokens", 0) or 0),
        int(u.get("cached_tokens", 0) or 0),
        int(details.get("cached_tokens", 0) or 0),
    )

def send(label, messages, **extra):
    payload = {"model": os.environ["KIMI_E2E_WIRE_MODEL"], "max_tokens": 30, "messages": messages}
    payload.update(extra)
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(f"{base_url}/chat/completions", data=body, headers=headers, method="POST")
    start = time.time()
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            elapsed = time.time() - start
            u = data.get("usage", {})
            prompt = int(u.get("prompt_tokens", 0) or u.get("input_tokens", 0) or 0)
            read = cache_read_from_usage(u)
            print(f"[{time.strftime('%X')}] {label}: prompt={prompt} cache_read={read} elapsed={elapsed:.2f}s", flush=True)
            return {"prompt": prompt, "cache_read": read, "usage": u}
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")[:300]
        print(f"[{time.strftime('%X')}] {label}: HTTP {e.code} {body}", flush=True)
        return None
    except Exception as e:
        print(f"[{time.strftime('%X')}] {label}: failed: {e}", flush=True)
        return None

salt = f"openai-boundary-{uuid.uuid4()}"
text = f"variant:{salt}\n" + ("This is meaningless filler text for OpenAI cache boundary testing. " * repeat) + "\nReply ok."
base_msgs = [{"role": "user", "content": text}]
extended_msgs = [
    {"role": "user", "content": text},
    {"role": "assistant", "content": "ok"},
    {"role": "user", "content": "follow-up. Reply ok again."},
]

warm = send("openai_warm", base_msgs)
time.sleep(3)
exact = send("openai_exact_probe", base_msgs)
time.sleep(1)
extended = send("openai_extended_probe", extended_msgs)

print()
if warm and exact and extended:
    floor256 = (warm["prompt"] // 256) * 256
    exact_ok = exact["cache_read"] >= warm["prompt"] * 0.95
    extended_ok = abs(extended["cache_read"] - floor256) < 256
    print(f"Exact re-send: cache_read={exact['cache_read']} warm_prompt={warm['prompt']} ({'OK' if exact_ok else 'MISMATCH'})")
    print(f"Prefix extension: cache_read={extended['cache_read']} expected_floor256={floor256} ({'OK' if extended_ok else 'MISMATCH'})")
    if exact_ok and extended_ok:
        print("Verdict: OpenAI endpoint matches Anthropic cache behavior for exact and prefix-extension probes.")
    else:
        print("Verdict: OpenAI endpoint cache behavior differs from Anthropic on this probe.")
else:
    print("Verdict: one or more OpenAI boundary requests failed; inconclusive.")
PY
  printf '\n'
}

# ---------------------------------------------------------------------------
# Test 4m: Provider PI_CACHE_RETENTION=none Behavior
# ---------------------------------------------------------------------------
# Runs through pi/provider, not direct curl. Confirms that disabling pi's cache
# knob removes prompt_cache_key injection but Kimi's content cache can still hit.
retention_none_provider_cache_check() {
  if [ "${KIMI_E2E_SKIP_RETENTION_NONE_PROVIDER:-0}" = "1" ]; then
    log "=== Test 4m: Provider PI_CACHE_RETENTION=none Behavior (skipped) ==="
    return 0
  fi

  log "=== Test 4m: Provider PI_CACHE_RETENTION=none Behavior (pi/provider) ==="

  EXT_DIR_PY="$EXT_DIR" PI_BIN_PY="$PI_BIN" python3 - <<'PY'
import json
import os
import subprocess
import tempfile
import time
import uuid

pi_bin = os.environ["PI_BIN_PY"]
ext_dir = os.environ["EXT_DIR_PY"]
model = os.environ.get("KIMI_E2E_MODEL", "kimi-coding/kimi-for-coding")
repeat = min(int(os.environ.get("KIMI_E2E_CACHE_REPEAT", "2000")), 1000)
prompt = f"retention-none:{uuid.uuid4()}\n" + ("This is meaningless filler text for provider cache testing. " * repeat) + "\nReply with only: ok"

# Candidate field names across pi versions / event shapes.
CACHE_READ_FIELDS = (
    "cacheRead", "cache_read",
    "cache_read_input_tokens", "cached_tokens",
)

def scan_for_usage(stdout_text):
    """Walk all JSON lines, look for any dict that contains a recognized
    cache-read field. Returns the first match as (value, field, event_type,
    location) or None."""
    for line in stdout_text.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(obj, dict):
            continue
        evt = obj.get("type", "<no-type>")
        # Try top-level usage and message.usage
        for path_label, container in (("usage", obj.get("usage")),
                                     ("message.usage", (obj.get("message") or {}).get("usage") if isinstance(obj.get("message"), dict) else None)):
            if isinstance(container, dict):
                for f in CACHE_READ_FIELDS:
                    v = container.get(f)
                    if v is not None:
                        try:
                            return (int(v), f, evt, path_label)
                        except (TypeError, ValueError):
                            pass
    return None

def run(label):
    env = os.environ.copy()
    env["PI_CACHE_RETENTION"] = "none"
    env["KIMI_CODE_PROTOCOL"] = "anthropic"
    start = time.time()
    proc = subprocess.run(
        [pi_bin, "-ne", "-e", ext_dir, "--model", model, "-p", prompt, "--mode", "json"],
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=180,
        check=False,
    )
    elapsed = time.time() - start

    # Always dump full output for post-mortem.
    fd, dump_path = tempfile.mkstemp(prefix=f"kimi_e2e_4m_{label}_", suffix=".jsonl")
    with os.fdopen(fd, "w") as f:
        f.write(proc.stdout)

    found = scan_for_usage(proc.stdout)
    if found is not None:
        value, field, evt, loc = found
        print(f"[{time.strftime('%X')}] {label}: exit={proc.returncode} cache_read={value} (field={field}, event={evt}, at={loc}) elapsed={elapsed:.2f}s dump={dump_path}", flush=True)
        return value
    else:
        # No usage info recognized. Surface tail for debugging.
        lines = proc.stdout.splitlines()
        tail = "\n  ".join(lines[-15:])
        print(f"[{time.strftime('%X')}] {label}: exit={proc.returncode} NO_USAGE_FOUND elapsed={elapsed:.2f}s dump={dump_path}", flush=True)
        print(f"  --- last 15 lines of pi stdout ---", flush=True)
        print(f"  {tail[:2500]}", flush=True)
        print(f"  --- end (full output at {dump_path}) ---", flush=True)
        return None

first = run("retention_none_warm")
time.sleep(3)
second = run("retention_none_probe")

print()
print(f"Results: warm_cacheRead={first} probe_cacheRead={second}")
if first is None or second is None:
    print("Verdict: could not extract cacheRead from pi output. Inspect the dump files above to determine pi's actual event shape, then update the parser.")
elif first == 0 and second > 0:
    print("Verdict: PI_CACHE_RETENTION=none does NOT prevent Kimi's content cache from hitting through the pi provider.")
elif second > 0:
    print(f"Verdict: provider cache hit observed (probe={second}), but warm request also reported cacheRead={first}. Either content was already cached or the warm/probe gap is too short.")
else:
    print("Verdict: no provider cache hit observed with PI_CACHE_RETENTION=none. Either payload varies (e.g. unique session id), or the prefix doesn't reach the cache layer.")
PY
  printf '\n'
}

# ---------------------------------------------------------------------------
# Test 4n: Usage Field Extraction Boundaries
# ---------------------------------------------------------------------------
# Keeps the cache-read detector honest across Anthropic, OpenAI top-level, and
# OpenAI prompt_tokens_details shapes, including null and string-number values.
usage_field_extraction_check() {
  if [ "${KIMI_E2E_SKIP_USAGE_FIELDS:-0}" = "1" ]; then
    log "=== Test 4n: Usage Field Extraction Boundaries (skipped) ==="
    return 0
  fi

  log "=== Test 4n: Usage Field Extraction Boundaries ==="

  python3 - <<'PY'
def cache_read_from_usage(u):
    details = u.get("prompt_tokens_details") or {}
    return max(
        int(u.get("cache_read_input_tokens", 0) or 0),
        int(u.get("cached_tokens", 0) or 0),
        int(details.get("cached_tokens", 0) or 0),
    )

cases = [
    ("anthropic_field", {"cache_read_input_tokens": 123}, 123),
    ("openai_top_level", {"cached_tokens": 456}, 456),
    ("openai_details", {"prompt_tokens_details": {"cached_tokens": 789}}, 789),
    ("max_of_all", {"cache_read_input_tokens": 10, "cached_tokens": 20, "prompt_tokens_details": {"cached_tokens": 30}}, 30),
    ("null_values", {"cache_read_input_tokens": None, "cached_tokens": None, "prompt_tokens_details": {"cached_tokens": None}}, 0),
    ("string_numbers", {"cache_read_input_tokens": "42", "cached_tokens": "7"}, 42),
    ("missing", {}, 0),
]

ok = True
for name, usage, expected in cases:
    got = cache_read_from_usage(usage)
    passed = got == expected
    ok = ok and passed
    print(f"  {name}: got={got} expected={expected} {'OK' if passed else 'FAIL'}")
print()
print("Verdict: usage cache-read extraction covers all known field shapes." if ok else "Verdict: usage cache-read extraction missed at least one field shape.")
PY
  printf '\n'
}

# ---------------------------------------------------------------------------
# Test 4o: Non-Prompt Parameter Cache Participation
# ---------------------------------------------------------------------------
# Same messages, probe with changed generation parameters. These should not
# invalidate the prompt-prefix cache if cache identity is prompt-only.
non_prompt_params_cache_check() {
  if [ "${KIMI_E2E_SKIP_NON_PROMPT_PARAMS:-0}" = "1" ]; then
    log "=== Test 4o: Non-Prompt Parameter Cache Participation (skipped) ==="
    return 0
  fi

  log "=== Test 4o: Non-Prompt Parameter Cache Participation (OpenAI endpoint) ==="

  python3 - <<'PY'
import json
import os
import time
import urllib.error
import urllib.request
import uuid

api_key = os.environ["KIMI_API_KEY"]
base_url = os.environ.get("KIMI_CODE_BASE_URL", "https://api.kimi.com/coding/v1").rstrip("/")
repeat = int(os.environ.get("KIMI_E2E_CACHE_REPEAT", "2000"))
alt_model = os.environ.get("KIMI_E2E_ALT_MODEL")

headers = {
    "Authorization": f"Bearer {api_key}",
    "content-type": "application/json",
    "User-Agent": "KimiCLI/1.44.0",
    "X-Msh-Platform": "kimi_cli",
    "X-Msh-Version": "1.44.0",
}

def cache_read_from_usage(u):
    details = u.get("prompt_tokens_details") or {}
    return max(int(u.get("cached_tokens", 0) or 0), int(details.get("cached_tokens", 0) or 0))

def send(label, messages, **extra):
    payload = {"model": os.environ["KIMI_E2E_WIRE_MODEL"], "max_tokens": 50, "messages": messages}
    payload.update(extra)
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(f"{base_url}/chat/completions", data=body, headers=headers, method="POST")
    start = time.time()
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            elapsed = time.time() - start
            u = data.get("usage", {})
            prompt = int(u.get("prompt_tokens", 0) or u.get("input_tokens", 0) or 0)
            read = cache_read_from_usage(u)
            print(f"[{time.strftime('%X')}] {label}: prompt={prompt} cache_read={read} elapsed={elapsed:.2f}s", flush=True)
            return {"prompt": prompt, "cache_read": read}
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")[:300]
        print(f"[{time.strftime('%X')}] {label}: HTTP {e.code} {body}", flush=True)
        return None
    except Exception as e:
        print(f"[{time.strftime('%X')}] {label}: failed: {e}", flush=True)
        return None

def run_variant(name, extra):
    salt = f"nonprompt-{name}-{uuid.uuid4()}"
    text = f"variant:{salt}\n" + ("This is meaningless filler text for non-prompt cache testing. " * repeat) + "\nReply ok."
    messages = [{"role": "user", "content": text}]
    warm = send(f"{name}_warm", messages)
    time.sleep(3)
    probe = send(f"{name}_probe", messages, **extra)
    return name, warm, probe

variants = [
    ("temperature", {"temperature": 0}),
    ("top_p", {"top_p": 0.5}),
    ("max_tokens", {"max_tokens": 5}),
    ("reasoning_effort", {"reasoning_effort": "low"}),
]
if alt_model:
    variants.append(("model", {"model": alt_model}))

rows = [run_variant(name, extra) for name, extra in variants]
print()
print("Non-prompt parameter results:")
all_ok = True
for name, warm, probe in rows:
    if warm is None or probe is None:
        print(f"  {name}: failed")
        all_ok = False
        continue
    ratio = probe["cache_read"] / warm["prompt"] if warm["prompt"] else 0
    ok = ratio > 0.9
    all_ok = all_ok and ok
    print(f"  {name}: cache_read={probe['cache_read']} warm_prompt={warm['prompt']} ratio={ratio:.1%} {'OK' if ok else 'MISMATCH'}")
print()
print("Verdict: generation parameters do not invalidate prompt cache." if all_ok else "Verdict: at least one non-prompt parameter changed cache behavior or failed.")
PY
  printf '\n'
}

# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Run this focused suite
# ---------------------------------------------------------------------------
tools_change_cache_check
small_boundary_cache_check
openai_cache_boundary_check
retention_none_provider_cache_check
usage_field_extraction_check
non_prompt_params_cache_check
log "E2E suite complete."
