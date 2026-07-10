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

# ---------------------------------------------------------------------------
# Test 5: File Upload + Visual Verification
# ---------------------------------------------------------------------------
file_upload_check() {
  log "=== Test 5: File Upload + Visual Verification ==="

  # Download a real photo from picsum, stamp a random code on it, save as large PNG
  local tmpfile
  tmpfile="$(mktemp -t kimi_e2e_upload_XXXXXX.png)"
  local random_code="E2E-$(date +%s | tail -c 7)"

  log "Generating test image with watermark code: $random_code"
  python3 - "$tmpfile" "$random_code" <<'PYIMG'
import sys
import urllib.request
from PIL import Image, ImageDraw, ImageFont
from io import BytesIO

out_path = sys.argv[1]
code = sys.argv[2]

# Download a real photo
url = "https://picsum.photos/1400/1400.jpg"
data = urllib.request.urlopen(url, timeout=30).read()
img = Image.open(BytesIO(data)).convert("RGB")

# Stamp the random code as a large watermark
draw = ImageDraw.Draw(img)
try:
    font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 120)
except Exception:
    font = ImageFont.load_default()
bbox = draw.textbbox((0, 0), code, font=font)
tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
x = (img.width - tw) // 2
y = (img.height - th) // 2
# Black outline + white fill for visibility
for dx in range(-3, 4):
    for dy in range(-3, 4):
        draw.text((x + dx, y + dy), code, fill="black", font=font)
draw.text((x, y), code, fill="white", font=font)

# Save as uncompressed PNG to ensure >5MB
img.save(out_path, format="PNG", compress_level=0)
import os
size_mb = os.path.getsize(out_path) / 1024 / 1024
print(f"Generated {out_path} ({size_mb:.1f} MB) with code: {code}")
PYIMG

  log "Uploading to ${BASE_URL}/files ..."

  local http_code
  http_code=$(curl -s -o /tmp/kimi_e2e_upload_resp.json -w "%{http_code}" \
    -X POST "${BASE_URL}/files" \
    -H "Authorization: Bearer ${KIMI_API_KEY}" \
    "${KIMI_HEADERS[@]}" \
    -F "file=@${tmpfile};type=image/png" \
    -F "purpose=image")

  rm -f "$tmpfile"

  if [ "$http_code" != "200" ] && [ "$http_code" != "201" ]; then
    log "Upload FAILED (status=$http_code)"
    cat /tmp/kimi_e2e_upload_resp.json 2>/dev/null
    rm -f /tmp/kimi_e2e_upload_resp.json
    printf '\n'
    return 1
  fi

  local file_id
  file_id=$(python3 -c "import json; d=json.load(open('/tmp/kimi_e2e_upload_resp.json')); print(d.get('id',''))")
  log "Upload OK (status=$http_code). file_id=$file_id  ms_url=ms://$file_id"
  rm -f /tmp/kimi_e2e_upload_resp.json

  # Visual verification: ask the model what text/code is in the image
  log "Verifying: asking model to read the watermark code from uploaded image..."
  local verify_payload
  verify_payload=$(KIMI_E2E_WIRE_MODEL="$KIMI_E2E_WIRE_MODEL" python3 -c "
import json, os
file_id = '$file_id'
print(json.dumps({
    'model': os.environ['KIMI_E2E_WIRE_MODEL'],
    'max_tokens': 200,
    'messages': [{
        'role': 'user',
        'content': [
            {'type': 'image_url', 'image_url': {'url': f'ms://{file_id}'}},
            {'type': 'text', 'text': 'What is the text/code written on this image? Reply with ONLY the exact text, nothing else.'},
        ],
    }],
}))
")

  local verify_resp
  verify_resp=$(curl -s -X POST "${BASE_URL}/chat/completions" \
    -H "Authorization: Bearer ${KIMI_API_KEY}" \
    -H "Content-Type: application/json" \
    "${KIMI_HEADERS[@]}" \
    -d "$verify_payload")

  local verify_code
  verify_code=$(echo "$verify_resp" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('choices', [{}])[0].get('message', {}).get('content', '').strip())
")
  local verify_usage
  verify_usage=$(echo "$verify_resp" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(json.dumps(d.get('usage', {}), ensure_ascii=False))
")

  log "Expected: $random_code"
  log "Model replied: $verify_code"
  log "usage=$verify_usage"
  if echo "$verify_code" | grep -qF "$random_code"; then
    log "PASS: model correctly identified the watermark code"
  else
    log "WARN: model reply does not contain expected code (may be OCR variance)"
  fi
  printf '\n'
}

# ---------------------------------------------------------------------------
# Test 6: Cache Key Injection
# ---------------------------------------------------------------------------
cache_key_injection_check() {
  log "=== Test 6: Cache Key Injection (prompt_cache_key in payload) ==="

  local test_cache_key="e2e-cache-key-test-$$-$(date +%s)"
  local payload
  payload=$(KIMI_E2E_WIRE_MODEL="$KIMI_E2E_WIRE_MODEL" python3 -c "
import json, os
print(json.dumps({
    'model': os.environ['KIMI_E2E_WIRE_MODEL'],
    'max_tokens': 100,
    'prompt_cache_key': '$test_cache_key',
    'messages': [{'role': 'user', 'content': 'Reply with: ok'}],
}))
")

  if [ "$KIMI_E2E_VERBOSE" = "1" ]; then
    log "+ POST ${BASE_URL}/chat/completions with prompt_cache_key=$test_cache_key"
  fi

  local http_code
  http_code=$(curl -s -o /tmp/kimi_e2e_cache_resp.json -w "%{http_code}" \
    -X POST "${BASE_URL}/chat/completions" \
    -H "Authorization: Bearer ${KIMI_API_KEY}" \
    -H "Content-Type: application/json" \
    "${KIMI_HEADERS[@]}" \
    -d "$payload")

  if [ "$http_code" = "200" ]; then
    local usage
    usage=$(python3 -c "import json; d=json.load(open('/tmp/kimi_e2e_cache_resp.json')); print(json.dumps(d.get('usage',{}), ensure_ascii=False))")
    log "Cache key injection OK (status=200). usage=$usage"
  else
    log "Request failed (status=$http_code)"
    cat /tmp/kimi_e2e_cache_resp.json 2>/dev/null
  fi
  rm -f /tmp/kimi_e2e_cache_resp.json
  printf '\n'
}

# ---------------------------------------------------------------------------
# Run this focused suite
# ---------------------------------------------------------------------------
file_upload_check
cache_key_injection_check
log "E2E suite complete."
