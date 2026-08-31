#!/bin/bash
# Integration tests for custodes endpoints
# Usage: ./test-endpoints.sh <dev|prod>
#
# Requires Node.js 18+ (for crypto.subtle ECIES encryption)

if [ -z "$1" ]; then
  echo "Usage: $0 <dev|prod>"
  exit 1
fi

case $1 in
  dev)  PORT=9444 ;;
  prod) PORT=8444 ;;
  *)    echo "Usage: $0 <dev|prod>"; exit 1 ;;
esac

BASE_URL="https://localhost:$PORT"

# The anti-freeloading gate origin baked into the image at build time. Sourced
# from the same config the build uses, so the upload tests forward the referrer
# the running server expects and the access-control test knows if the gate is on.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ALLOWED_REFERRER_ORIGIN=""
[ -f "$SCRIPT_DIR/build-config.sh" ] && source "$SCRIPT_DIR/build-config.sh"
FAILED=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILED=1; }

echo "Testing custodes endpoints ($1 - port $PORT)"
echo "========================================="

# Test /tools
echo "--- /tools ---"
TOOLS=$(curl -sk "$BASE_URL/tools")
if echo "$TOOLS" | grep -q '"tool_name":"cppcheck"'; then
  pass "lists cppcheck"
else
  fail "cppcheck not found in response"
fi
if echo "$TOOLS" | grep -q '"tool_name":"binwalk"'; then
  pass "lists binwalk"
else
  fail "binwalk not found in response"
fi
if echo "$TOOLS" | grep -q '"tool_name":"aeskeyfind"'; then
  pass "lists aeskeyfind"
else
  fail "aeskeyfind not found in response"
fi

# Test /quote
echo "--- /quote ---"
QUOTE=$(curl -sk "$BASE_URL/quote")
if echo "$QUOTE" | grep -q '"quote_data"'; then
  pass "returns quote_data"
else
  fail "no quote_data in response"
fi

# Test /rtmr2
echo "--- /rtmr2 ---"
RTMR2=$(curl -sk "$BASE_URL/rtmr2")
if echo "$RTMR2" | grep -q '"rtmr2"'; then
  pass "returns rtmr2"
else
  fail "no rtmr2 in response"
fi

# Test /measurements. Added with the Step 2 boot-chain pinning: the client pins MRTD
# and RTMR1 as hard failures, so this endpoint agreeing with the image's .meta is what
# makes a client bundle and a running image a matched pair. RTMR0 is deliberately not
# compared -- it is warn-only in the verifier because it churns with the QEMU/OVMF
# version, and it legitimately differs on a boot that adds a serial device.
echo "--- /measurements ---"
case $1 in
  dev)  META="$SCRIPT_DIR/verity-dev-image.img.meta" ;;
  prod) META="$SCRIPT_DIR/verity-image.img.meta" ;;
esac
MEAS=$(curl -sk "$BASE_URL/measurements")
json_field() { echo "$1" | grep -o "\"$2\":\"[^\"]*\"" | cut -d'"' -f4; }
meta_field() { grep "^$1=" "$META" | cut -d= -f2; }

if echo "$MEAS" | grep -q '"mrTd"'; then
  pass "returns all measurements"
else
  fail "no mrTd in response"
fi

if [ "$(json_field "$MEAS" rtmr2)" = "$(echo "$RTMR2" | grep -o '"rtmr2":"[^"]*"' | cut -d'"' -f4)" ]; then
  pass "rtmr2 agrees with /rtmr2"
else
  fail "rtmr2 disagrees between /measurements and /rtmr2"
fi

if [ -f "$META" ]; then
  MATCHED=true
  check_meta() {
    if [ "$(meta_field "$1")" != "$(json_field "$MEAS" "$2")" ]; then
      fail "$1 does not match $META"
      MATCHED=false
    fi
  }
  check_meta MRTD  mrTd
  check_meta RTMR1 rtmr1
  check_meta RTMR2 rtmr2
  [ "$MATCHED" = true ] && pass "MRTD/RTMR1/RTMR2 match the recorded .meta"
else
  echo "  SKIP: $META not found"
fi

# RTMR3 must stay all zeros and the TD debug bit must be clear -- both are hard
# failures in the verifier, so catch a violation here rather than in a browser.
if [ "$(json_field "$MEAS" rtmr3)" = "$(printf '0%.0s' $(seq 96))" ]; then
  pass "rtmr3 is all zeros"
else
  fail "rtmr3 is not all zeros"
fi

TDATTR=$(json_field "$MEAS" tdAttributes)
if [ $(( 0x${TDATTR:0:2} & 1 )) -eq 0 ]; then
  pass "TD debug bit clear ($TDATTR)"
else
  fail "TD debug bit is SET ($TDATTR) - guest memory is host-inspectable"
fi

# Test /upload access control (anti-freeloading referrer gate).
# The gate runs before decryption, so a forged/missing referrer is rejected with
# HTTP 402 using only a well-formed (version 1) envelope — no valid ciphertext
# needed. The accepted-referrer path is covered by the tool tests below, which
# forward $ALLOWED_REFERRER_ORIGIN and only succeed if the gate lets them through.
echo "--- /upload access control ---"
check_upload_rejected() {
  local LABEL="$1" REFERRER="$2"
  local CODE
  CODE=$(curl -sk -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/upload" \
    -H 'Content-Type: application/json' \
    -d "{\"version\":1,\"ephemeral_public_key\":\"\",\"nonce\":\"\",\"ciphertext\":\"\",\"referrer\":\"$REFERRER\"}")
  if [ "$CODE" = "402" ]; then
    pass "$LABEL (HTTP 402)"
  else
    fail "$LABEL (expected 402, got $CODE)"
  fi
}
if [ -n "$ALLOWED_REFERRER_ORIGIN" ]; then
  check_upload_rejected "forged referrer rejected"  "https://evil.example"
  check_upload_rejected "missing referrer rejected" ""
else
  echo "  SKIP: referrer gate disabled (ALLOWED_REFERRER_ORIGIN empty in build-config.sh)"
fi

# Encrypted upload + result helper
# Usage: run_tool_test <tool_label> <tool_name> <toe_base64> <parameters_json>
run_tool_test() {
  local LABEL="$1" TOOL_NAME="$2" TOE_B64="$3" PARAMS_JSON="$4"
  echo "--- /upload + /result ($LABEL) ---"
  local RESULT
  RESULT=$(BASE_URL="$BASE_URL" TOOL_NAME="$TOOL_NAME" TOE_B64="$TOE_B64" PARAMS_JSON="$PARAMS_JSON" \
    REFERRER="$ALLOWED_REFERRER_ORIGIN" \
    NODE_TLS_REJECT_UNAUTHORIZED=0 node 2>/dev/null <<'NODESCRIPT'
const crypto = require('node:crypto').webcrypto;
const { BASE_URL, TOOL_NAME, TOE_B64, PARAMS_JSON, REFERRER } = process.env;

function toBase64(u) { return Buffer.from(u).toString('base64'); }
function fromBase64(b) { return new Uint8Array(Buffer.from(b, 'base64')); }

function extractPubKeyFromQuote(quoteB64) {
  const buf = fromBase64(quoteB64);
  return buf.slice(568, 568 + 64);
}

async function encryptPayload(serverPubKey64, plaintextBytes) {
  const serverKeyBytes = new Uint8Array(65);
  serverKeyBytes[0] = 0x04;
  serverKeyBytes.set(serverPubKey64, 1);
  const serverECDHKey = await crypto.subtle.importKey(
    'raw', serverKeyBytes, { name: 'ECDH', namedCurve: 'P-256' }, false, []
  );
  const ephPair = await crypto.subtle.generateKey(
    { name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']
  );
  const sharedBits = await crypto.subtle.deriveBits(
    { name: 'ECDH', public: serverECDHKey }, ephPair.privateKey, 256
  );
  const hkdfKey = await crypto.subtle.importKey('raw', sharedBits, 'HKDF', false, ['deriveKey']);
  const aesKey = await crypto.subtle.deriveKey(
    { name: 'HKDF', hash: 'SHA-256', salt: new Uint8Array(0), info: new TextEncoder().encode('RTE-upload-encryption-v1') },
    hkdfKey, { name: 'AES-GCM', length: 128 }, false, ['encrypt']
  );
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce }, aesKey, plaintextBytes);
  const ephPubBytes = await crypto.subtle.exportKey('raw', ephPair.publicKey);
  return {
    version: 1,
    ephemeral_public_key: toBase64(new Uint8Array(ephPubBytes)),
    nonce: toBase64(nonce),
    ciphertext: toBase64(new Uint8Array(ciphertext))
  };
}

async function run() {
  const quoteResp = await fetch(BASE_URL + '/quote', { method: 'GET' });
  if (!quoteResp.ok) { console.log('FAIL_QUOTE'); return; }
  const quoteJson = await quoteResp.json();
  const pubKey = extractPubKeyFromQuote(quoteJson.quote_data);

  const payload = {
    toe: { format: 'bin', base64_encoded_toe: TOE_B64 },
    test: { tool_name: TOOL_NAME, parameters: JSON.parse(PARAMS_JSON) }
  };
  const plaintext = new TextEncoder().encode(JSON.stringify(payload));
  const encrypted = await encryptPayload(pubKey, plaintext);
  // Forward the navigation referrer the browser client would send, so the
  // upload passes the anti-freeloading gate (no-op when the gate is disabled).
  encrypted.referrer = REFERRER || '';

  const uploadResp = await fetch(BASE_URL + '/upload', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(encrypted)
  });
  if (!uploadResp.ok) { console.log('FAIL_UPLOAD'); return; }
  const uploadText = await uploadResp.text();
  const jobMatch = uploadText.match(/"jobID"\s*:\s*"([^"]+)"/);
  if (!jobMatch) { console.log('FAIL_JOBID'); return; }
  const jobID = jobMatch[1];

  for (let i = 0; i < 15; i++) {
    await new Promise(r => setTimeout(r, 2000));
    const resultResp = await fetch(BASE_URL + '/result', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ jobID })
    });
    const resultJson = await resultResp.json();
    if (resultJson.status === 'done') {
      if (resultJson.quote_data && resultJson.crypto_verification_data && resultJson.test) {
        console.log('OK:' + jobID);
      } else {
        console.log('FAIL_FIELDS');
      }
      return;
    }
    if (resultJson.status === 'error') {
      console.log('FAIL_ERROR:' + (resultJson.reason || 'unknown'));
      return;
    }
  }
  console.log('FAIL_TIMEOUT');
}

run().catch(e => console.log('FAIL_EXCEPTION:' + e.message));
NODESCRIPT
  )

  case "$RESULT" in
    OK:*)
      JOB_ID="${RESULT#OK:}"
      pass "$LABEL: encrypted upload + result (jobID: $JOB_ID)"
      ;;
    FAIL_QUOTE)      fail "$LABEL: could not fetch /quote" ;;
    FAIL_UPLOAD)     fail "$LABEL: upload request failed" ;;
    FAIL_JOBID)      fail "$LABEL: no jobID in upload response" ;;
    FAIL_FIELDS)     fail "$LABEL: result missing expected fields" ;;
    FAIL_TIMEOUT)    fail "$LABEL: result polling timed out" ;;
    FAIL_ERROR*)     fail "$LABEL: result returned error: $RESULT" ;;
    FAIL_EXCEPTION*) fail "$LABEL: node exception: $RESULT" ;;
    *)               fail "$LABEL: unexpected output: $RESULT" ;;
  esac
}

# Test cppcheck upload
CPPCHECK_TOE=$(echo -n 'int main() { return 0; }' | base64 -w0)
run_tool_test "cppcheck" "cppcheck" "$CPPCHECK_TOE" "[]"

# Test binwalk upload (minimal gzip header — binwalk will identify the signature)
BINWALK_TOE=$(printf '\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03' | cat - /dev/zero 2>/dev/null | head -c 74 | base64 -w0)
run_tool_test "binwalk" "binwalk" "$BINWALK_TOE" "[]"

# Test aeskeyfind upload
# Generate a 4KB blob with a valid AES-128 key schedule embedded in random-looking data.
# Zero padding triggers aeskeyfind's entropy filter, so we use pseudo-random fill instead.
# The -q flag suppresses the progress bar (which goes to stderr and pollutes results).
AESKEYFIND_TOE=$(python3 -c "
import hashlib
SBOX = [0]*256
p, q = 1, 1
while True:
    p ^= (p << 1) ^ (0x1b if p & 0x80 else 0); p &= 0xff
    q ^= q << 1; q ^= q << 2; q ^= q << 4
    q ^= 0x09 if q & 0x80 else 0; q &= 0xff
    v = q ^ ((q<<1)|(q>>7)) ^ ((q<<2)|(q>>6)) ^ ((q<<3)|(q>>5)) ^ ((q<<4)|(q>>4))
    v = (v ^ 0x63) & 0xff
    SBOX[p] = v
    if p == 1: break
SBOX[0] = 0x63
RCON = [0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80,0x1b,0x36]
key = bytes([0x2b,0x7e,0x15,0x16,0x28,0xae,0xd2,0xa6,0xab,0xf7,0x15,0x88,0x09,0xcf,0x4f,0x3c])
schedule = bytearray(key)
for i in range(10):
    prev = schedule[-16:]
    t = bytearray([SBOX[prev[13]], SBOX[prev[14]], SBOX[prev[15]], SBOX[prev[12]]])
    t[0] ^= RCON[i]
    w = bytearray(16)
    for j in range(4):
        for k in range(4):
            if j == 0: w[k] = prev[k] ^ t[k]
            else: w[j*4+k] = w[(j-1)*4+k] ^ prev[j*4+k]
    schedule.extend(w)
# pseudo-random fill (deterministic, no os.urandom needed)
fill = b''
for i in range(128):
    fill += hashlib.sha256(i.to_bytes(4,'big')).digest()
import sys; sys.stdout.buffer.write(fill[:2048] + bytes(schedule) + fill[2048:2048+1872])
" | base64 -w0)
run_tool_test "aeskeyfind" "aeskeyfind" "$AESKEYFIND_TOE" '[{"param_name":"-q","value":null}]'

echo "========================================="
if [ $FAILED -eq 0 ]; then
  echo "All tests passed"
  exit 0
else
  echo "Some tests failed"
  exit 1
fi
