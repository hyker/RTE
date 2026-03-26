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

# Encrypted upload + result helper
# Usage: run_tool_test <tool_label> <tool_name> <toe_base64> <parameters_json>
run_tool_test() {
  local LABEL="$1" TOOL_NAME="$2" TOE_B64="$3" PARAMS_JSON="$4"
  echo "--- /upload + /result ($LABEL) ---"
  local RESULT
  RESULT=$(BASE_URL="$BASE_URL" TOOL_NAME="$TOOL_NAME" TOE_B64="$TOE_B64" PARAMS_JSON="$PARAMS_JSON" \
    NODE_TLS_REJECT_UNAUTHORIZED=0 node 2>/dev/null <<'NODESCRIPT'
const crypto = require('node:crypto').webcrypto;
const { BASE_URL, TOOL_NAME, TOE_B64, PARAMS_JSON } = process.env;

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

echo "========================================="
if [ $FAILED -eq 0 ]; then
  echo "All tests passed"
  exit 0
else
  echo "Some tests failed"
  exit 1
fi
