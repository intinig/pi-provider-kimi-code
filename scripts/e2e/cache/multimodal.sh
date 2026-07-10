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
# Test 4p: Multimodal Cache Boundary
# ---------------------------------------------------------------------------
# Probes whether image_url content participates in cache identity: same
# text+image should hit, while same text with a different image should not
# receive the full exact-prompt hit.
multimodal_cache_check() {
  if [ "${KIMI_E2E_SKIP_MULTIMODAL_CACHE:-0}" = "1" ]; then
    log "=== Test 4p: Multimodal Cache Boundary (skipped) ==="
    return 0
  fi

  log "=== Test 4p: Multimodal Cache Boundary (OpenAI endpoint) ==="

  python3 - <<'PY'
import io
import json
import os
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import uuid

from PIL import Image

api_key = os.environ["KIMI_API_KEY"]
base_url = os.environ.get("KIMI_CODE_BASE_URL", "https://api.kimi.com/coding/v1").rstrip("/")

headers = {
    "Authorization": f"Bearer {api_key}",
    "content-type": "application/json",
    "User-Agent": "KimiCLI/1.44.0",
    "X-Msh-Platform": "kimi_cli",
    "X-Msh-Version": "1.44.0",
}

def make_png(color):
    """Generate a small distinct PNG file. color is (r, g, b)."""
    fd, path = tempfile.mkstemp(suffix=".png", prefix="kimi_e2e_4p_")
    os.close(fd)
    Image.new("RGB", (64, 64), color).save(path, "PNG")
    return path

def upload(path):
    """Upload a file to /files via curl (Kimi rejects inline data: URIs).
    Returns the file_id or None on failure."""
    proc = subprocess.run(
        [
            "curl", "-s", "-X", "POST", f"{base_url}/files",
            "-H", f"Authorization: Bearer {api_key}",
            "-H", "User-Agent: KimiCLI/1.44.0",
            "-H", "X-Msh-Platform: kimi_cli",
            "-H", "X-Msh-Version: 1.44.0",
            "-F", f"file=@{path};type=image/png",
            "-F", "purpose=image",
        ],
        capture_output=True, text=True, timeout=60, check=False,
    )
    try:
        data = json.loads(proc.stdout)
    except Exception:
        print(f"upload parse failed for {path}: {proc.stdout[:200]}", flush=True)
        return None
    file_id = data.get("id")
    if not file_id:
        print(f"upload missing id for {path}: {data}", flush=True)
        return None
    return file_id

path_a = make_png((255, 0, 0))   # red
path_b = make_png((0, 255, 0))   # green
file_a = upload(path_a)
file_b = upload(path_b)
os.unlink(path_a)
os.unlink(path_b)

if not file_a or not file_b:
    print("Verdict: image upload failed; cannot run multimodal cache probe.")
    raise SystemExit(0)

IMG_A = f"ms://{file_a}"
IMG_B = f"ms://{file_b}"
print(f"Uploaded images: A={IMG_A}  B={IMG_B}", flush=True)

def cache_read_from_usage(u):
    details = u.get("prompt_tokens_details") or {}
    return max(int(u.get("cached_tokens", 0) or 0), int(details.get("cached_tokens", 0) or 0))

def send(label, image_url, text):
    payload = {
        "model": os.environ["KIMI_E2E_WIRE_MODEL"],
        "max_tokens": 30,
        "messages": [{"role": "user", "content": [
            {"type": "image_url", "image_url": {"url": image_url}},
            {"type": "text", "text": text},
        ]}],
    }
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

salt = f"multimodal-{uuid.uuid4()}"
text = f"multimodal-cache:{salt}\nDescribe the image in one word, then say ok."
warm = send("mm_warm_A", IMG_A, text)
time.sleep(3)
exact = send("mm_exact_A", IMG_A, text)
time.sleep(1)
diff_img = send("mm_diff_image_B", IMG_B, text)

print()
if warm and exact and diff_img:
    exact_ratio = exact["cache_read"] / warm["prompt"] if warm["prompt"] else 0
    diff_ratio = diff_img["cache_read"] / warm["prompt"] if warm["prompt"] else 0
    print(f"Exact same image+text ratio: {exact_ratio:.1%}")
    print(f"Different image, same text ratio: {diff_ratio:.1%}")
    if exact_ratio > 0.9 and diff_ratio < 0.5:
        print("Verdict: image content participates in cache identity (same image hits, different image misses).")
    elif exact_ratio > 0.9 and diff_ratio > 0.9:
        print("Verdict: surprising — different images still read most of the cached prefix. Image content may NOT participate in hash.")
    elif exact_ratio > 0.9:
        print(f"Verdict: same image+text re-send hits ({exact_ratio:.1%}); different image partially hits ({diff_ratio:.1%}).")
    else:
        print("Verdict: multimodal exact cache did not hit; investigate further.")
else:
    print("Verdict: multimodal cache probe failed; one or more requests errored.")
PY
  printf '\n'
}

# ---------------------------------------------------------------------------
# Test 4q: Concurrent Same-Prefix Cache Writes
# ---------------------------------------------------------------------------
# Sends identical requests concurrently, then probes exact and prefix-extension
# reads. This catches racey cache writes or inconsistent same-prefix behavior.
concurrent_cache_check() {
  if [ "${KIMI_E2E_SKIP_CONCURRENT_CACHE:-0}" = "1" ]; then
    log "=== Test 4q: Concurrent Same-Prefix Cache Writes (skipped) ==="
    return 0
  fi

  log "=== Test 4q: Concurrent Same-Prefix Cache Writes (Anthropic endpoint) ==="

  python3 - <<'PY'
import concurrent.futures
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
    "x-api-key": api_key,
    "anthropic-version": "2023-06-01",
    "content-type": "application/json",
    "User-Agent": "KimiCLI/1.44.0",
    "X-Msh-Platform": "kimi_cli",
    "X-Msh-Version": "1.44.0",
}

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

salt = f"concurrent-{uuid.uuid4()}"
text = f"concurrent-cache:{salt}\n" + ("This is meaningless filler text for concurrent cache testing. " * repeat) + "\nReply ok."
base_msgs = [{"role": "user", "content": [{"type": "text", "text": text}]}]
extended_msgs = [
    {"role": "user", "content": [{"type": "text", "text": text}]},
    {"role": "assistant", "content": [{"type": "text", "text": "ok"}]},
    {"role": "user", "content": [{"type": "text", "text": "follow-up. Reply ok again."}]},
]

with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
    warms = list(pool.map(lambda i: send(f"concurrent_warm_{i}", base_msgs), range(5)))

time.sleep(3)
exact = send("concurrent_exact_probe", base_msgs)
extended = send("concurrent_extended_probe", extended_msgs)

print()
successful_warms = [r for r in warms if r is not None]
if successful_warms and exact and extended:
    warm_prompt = successful_warms[0]["prompt"]
    floor256 = (warm_prompt // 256) * 256
    exact_ok = exact["cache_read"] >= warm_prompt * 0.95
    extended_ok = abs(extended["cache_read"] - floor256) < 256
    print(f"Warm requests succeeded: {len(successful_warms)}/5")
    print(f"Exact probe: cache_read={exact['cache_read']} warm_prompt={warm_prompt} {'OK' if exact_ok else 'MISMATCH'}")
    print(f"Extended probe: cache_read={extended['cache_read']} floor256={floor256} {'OK' if extended_ok else 'MISMATCH'}")
    if len(successful_warms) == 5 and exact_ok and extended_ok:
        print("Verdict: concurrent same-prefix writes are stable for exact and prefix-extension probes.")
    else:
        print("Verdict: concurrent same-prefix behavior had failures or cache mismatches.")
else:
    print("Verdict: concurrent same-prefix probe failed; inconclusive.")
PY
  printf '\n'
}

# ---------------------------------------------------------------------------
# Test 4r: Very Large Context Cache Boundary (long-running, off by default)
# ---------------------------------------------------------------------------
# Pushes the chunk-alignment and exact re-send checks into ~100K-token prompts.
# Set KIMI_E2E_SKIP_VERY_LARGE_CACHE=0 to enable.
very_large_cache_check() {
  if [ "${KIMI_E2E_SKIP_VERY_LARGE_CACHE:-1}" = "1" ]; then
    log "=== Test 4r: Very Large Context Cache Boundary (skipped — set KIMI_E2E_SKIP_VERY_LARGE_CACHE=0 to enable) ==="
    return 0
  fi

  log "=== Test 4r: Very Large Context Cache Boundary (Anthropic endpoint) ==="

  python3 - <<'PY'
import json
import os
import time
import urllib.error
import urllib.request
import uuid

api_key = os.environ["KIMI_API_KEY"]
base_url = os.environ.get("KIMI_CODE_BASE_URL", "https://api.kimi.com/coding/v1").rstrip("/")
repeat = int(os.environ.get("KIMI_E2E_VERY_LARGE_REPEAT", "12000"))

headers = {
    "x-api-key": api_key,
    "anthropic-version": "2023-06-01",
    "content-type": "application/json",
    "User-Agent": "KimiCLI/1.44.0",
    "X-Msh-Platform": "kimi_cli",
    "X-Msh-Version": "1.44.0",
}

def cache_read_from_usage(u):
    return max(int(u.get("cache_read_input_tokens", 0) or 0), int(u.get("cached_tokens", 0) or 0))

def send(label, messages):
    payload = {"model": os.environ["KIMI_E2E_WIRE_MODEL"], "max_tokens": 20, "messages": messages}
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(f"{base_url}/messages", data=body, headers=headers, method="POST")
    start = time.time()
    try:
        with urllib.request.urlopen(req, timeout=300) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            elapsed = time.time() - start
            u = data.get("usage", {})
            prompt = int(u.get("prompt_tokens", 0) or u.get("input_tokens", 0) or 0)
            read = cache_read_from_usage(u)
            print(f"[{time.strftime('%X')}] {label}: prompt={prompt} cache_read={read} elapsed={elapsed:.2f}s", flush=True)
            return {"prompt": prompt, "cache_read": read}
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")[:500]
        print(f"[{time.strftime('%X')}] {label}: HTTP {e.code} {body}", flush=True)
        return None
    except Exception as e:
        print(f"[{time.strftime('%X')}] {label}: failed: {e}", flush=True)
        return None

salt = f"very-large-{uuid.uuid4()}"
text = f"very-large-cache:{salt}\n" + ("large context cache boundary padding phrase with stable tokens. " * repeat) + "\nReply ok."
base_msgs = [{"role": "user", "content": [{"type": "text", "text": text}]}]
extended_msgs = [
    {"role": "user", "content": [{"type": "text", "text": text}]},
    {"role": "assistant", "content": [{"type": "text", "text": "ok"}]},
    {"role": "user", "content": [{"type": "text", "text": "tiny tail after very large prefix. Reply ok."}]},
]

print(f"repeat={repeat}", flush=True)
warm = send("very_large_warm", base_msgs)
time.sleep(3)
exact = send("very_large_exact", base_msgs)
time.sleep(1)
extended = send("very_large_extended", extended_msgs)

print()
if warm and exact and extended:
    floor256 = (warm["prompt"] // 256) * 256
    exact_ok = exact["cache_read"] >= warm["prompt"] * 0.95
    extended_ok = abs(extended["cache_read"] - floor256) < 256
    size_ok = warm["prompt"] >= 100000
    print(f"Prompt size: {warm['prompt']} tokens ({'>=100K' if size_ok else '<100K; increase KIMI_E2E_VERY_LARGE_REPEAT'})")
    print(f"Exact probe: cache_read={exact['cache_read']} warm_prompt={warm['prompt']} {'OK' if exact_ok else 'MISMATCH'}")
    print(f"Extended probe: cache_read={extended['cache_read']} floor256={floor256} {'OK' if extended_ok else 'MISMATCH'}")
    if size_ok and exact_ok and extended_ok:
        print("Verdict: very large prompt cache matches exact and 256-floor prefix behavior.")
    elif exact_ok and extended_ok:
        print("Verdict: cache behavior matched, but prompt did not reach 100K tokens.")
    else:
        print("Verdict: very large prompt cache behavior differed or request hit a context/API boundary.")
else:
    print("Verdict: very large cache probe failed; likely context limit, timeout, or endpoint rejection.")
PY
  printf '\n'
}

# ---------------------------------------------------------------------------
# Test 4s: Device ID Cache Participation
# ---------------------------------------------------------------------------
# Provider sends X-Msh-Device-Id on every request (src/device.ts), but every
# other 4* test above omits the header. That means those tests only prove
# cache behavior under "no-device-id" headers, not across distinct device
# ids. This test answers: does X-Msh-Device-Id participate in cache identity?
# i.e. do two agents on different machines (different device ids, same API
# token, same content) share Kimi's prompt cache, or does each device get a
# private slot?
#
#   V0 same device (A->A):   sanity baseline; identical content + header must
#                            HIT.
#   V1 different device:     warm A, probe B with identical payload.
#                            HIT   => device id is IGNORED (cache shared
#                                     across devices / agents / forks)
#                            MISS  => device id PARTITIONS cache (each device
#                                     cold-starts; losing ~/.pi/providers/
#                                     kimi-coding/device_id forces a re-warm)
#   V2/V3 no-header vs A:    characterizes whether the "no X-Msh-Device-Id"
#                            bucket is separate from explicit device ids.
device_id_cache_check() {
  if [ "${KIMI_E2E_SKIP_DEVICE_ID_CACHE:-0}" = "1" ]; then
    log "=== Test 4s: Device ID Cache Participation (skipped) ==="
    return 0
  fi

  log "=== Test 4s: Device ID Cache Participation (Anthropic endpoint) ==="

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
base_url = os.environ.get("KIMI_CODE_BASE_URL", "https://api.kimi.com/coding/v1").rstrip("/")

filler = "This is meaningless filler text for testing device-id cache impact. " * repeat

BASE_HEADERS = {
    "x-api-key": api_key,
    "anthropic-version": "2023-06-01",
    "content-type": "application/json",
    "User-Agent": "KimiCLI/1.44.0",
    "X-Msh-Platform": "kimi_cli",
    "X-Msh-Version": "1.44.0",
}

def headers_with(device_id):
    h = dict(BASE_HEADERS)
    if device_id is not None:
        h["X-Msh-Device-Id"] = device_id
    return h

def build_payload(salt):
    text = f"variant:{salt}\n{filler}\n\nReply with only: ok"
    return {
        "model": os.environ["KIMI_E2E_WIRE_MODEL"],
        "max_tokens": 50,
        "messages": [{"role": "user", "content": [{"type": "text", "text": text}]}],
    }

def send(label, payload, headers):
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(f"{base_url}/messages", data=body, headers=headers, method="POST")
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
            if verbose:
                print(f"  usage={json.dumps(u, ensure_ascii=False)}", flush=True)
            return cache_read, prompt
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")[:300]
        print(f"[{time.strftime('%X')}] {label}: HTTP {e.code} {body}", flush=True)
        return -1, -1
    except Exception as e:
        print(f"[{time.strftime('%X')}] {label}: failed: {e}", flush=True)
        return -1, -1

# 32-char hex matches kimi-cli's randomBytes(16).toString("hex").
device_a = uuid.uuid4().hex
device_b = uuid.uuid4().hex
print(f"device_A={device_a}", flush=True)
print(f"device_B={device_b}", flush=True)

def run_scenario(name, warm_dev, probe_dev):
    salt = f"devid-{name}-{uuid.uuid4()}"
    payload = build_payload(salt)
    warm_label = warm_dev or "(no header)"
    probe_label = probe_dev or "(no header)"
    print(f"--- {name}: warm={warm_label} -> probe={probe_label} ---", flush=True)
    send(f"{name}_warm", payload, headers_with(warm_dev))
    time.sleep(3)
    return send(f"{name}_probe", payload, headers_with(probe_dev))

v0_read, v0_prompt = run_scenario("V0_same_device",            device_a, device_a)
v1_read, v1_prompt = run_scenario("V1_diff_device",            device_a, device_b)
v2_read, v2_prompt = run_scenario("V2_warm_none_probe_devA",   None,     device_a)
v3_read, v3_prompt = run_scenario("V3_warm_devA_probe_none",   device_a, None)

print()
print("Results:")
print(f"  V0 same device (A->A):       cache_read={v0_read} / prompt={v0_prompt}")
print(f"  V1 different device (A->B):  cache_read={v1_read} / prompt={v1_prompt}")
print(f"  V2 no header -> device-A:    cache_read={v2_read} / prompt={v2_prompt}")
print(f"  V3 device-A -> no header:    cache_read={v3_read} / prompt={v3_prompt}")

print()
if v0_read > 0:
    def ratio(r):
        return (r / v0_read) if (r >= 0 and v0_read > 0) else 0
    r1 = ratio(v1_read)
    r2 = ratio(v2_read)
    r3 = ratio(v3_read)
    print(f"Ratios vs V0 baseline: V1={r1:.1%}  V2={r2:.1%}  V3={r3:.1%}")
    print()
    if r1 > 0.9 and r2 > 0.9 and r3 > 0.9:
        print("Verdict: X-Msh-Device-Id is IGNORED for cache identity.")
        print("  - Cache is shared across distinct device ids and across no-header requests.")
        print("  - Multi-machine / multi-agent fork can reuse each other's cache for free.")
        print("  - Losing ~/.pi/providers/kimi-coding/device_id does NOT force a cold prefix.")
    elif r1 < 0.2 and r2 < 0.2 and r3 < 0.2:
        print("Verdict: X-Msh-Device-Id fully PARTITIONS the cache.")
        print("  - Each device id gets a private slot; switching devices forces a cold re-warm.")
        print("  - Provider behavior: every machine pays its own warmup cost.")
    elif r1 < 0.2 and r2 > 0.9 and r3 > 0.9:
        print("Verdict: device id PARTITIONS cache only when both sides set distinct ids.")
        print("  - Omitting the header lands in the same bucket as device-A (header treated as absent or default).")
    else:
        print(f"Verdict: mixed (V1={r1:.1%} V2={r2:.1%} V3={r3:.1%}). Inspect ratios above.")
else:
    print("Verdict: V0 baseline did not cache; cannot interpret remaining scenarios.")
    print("  Either the warm->probe gap is too short, or content cache is disabled for this key.")
PY
  printf '\n'
}

# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Run this focused suite
# ---------------------------------------------------------------------------
multimodal_cache_check
concurrent_cache_check
very_large_cache_check
device_id_cache_check
log "E2E suite complete."
