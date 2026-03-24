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

# Test /upload + /result (encrypted upload via Node.js helper)
echo "--- /upload + /result ---"
RESULT=$(BASE_URL="$BASE_URL" NODE_TLS_REJECT_UNAUTHORIZED=0 node 2>/dev/null <<'NODESCRIPT'
const crypto = require('node:crypto').webcrypto;

const BASE_URL = process.env.BASE_URL;

function toBase64(uint8Array) {
  return Buffer.from(uint8Array).toString('base64');
}
function fromBase64(b64) {
  return new Uint8Array(Buffer.from(b64, 'base64'));
}

// Extract the 64-byte reportData (enclave public key) from a TDX quote
// Header: 48 bytes, body fields before reportData: 520 bytes → offset 568
function extractPubKeyFromQuote(quoteB64) {
  const buf = fromBase64(quoteB64);
  return buf.slice(568, 568 + 64);
}

// ECIES encrypt: ECDH (ephemeral P-256) + HKDF-SHA256 + AES-128-GCM
// Mirrors client/browser-client.js encryptPayload()
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
    hkdfKey,
    { name: 'AES-GCM', length: 128 }, false, ['encrypt']
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
  // 1. Get quote and extract enclave public key
  const quoteResp = await fetch(BASE_URL + '/quote', { method: 'GET' });
  if (!quoteResp.ok) { console.log('FAIL_QUOTE'); return; }
  const quoteJson = await quoteResp.json();
  const pubKey = extractPubKeyFromQuote(quoteJson.quote_data);

  // 2. Build and encrypt upload payload
  const toeContent = Buffer.from('int main() { return 0; }').toString('base64');
  const payload = {
    toe: { format: 'c', base64_encoded_toe: toeContent },
    test: { tool_name: 'cppcheck', parameters: [] }
  };
  const plaintext = new TextEncoder().encode(JSON.stringify(payload));
  const encrypted = await encryptPayload(pubKey, plaintext);

  // 3. Upload
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

  // 4. Poll for result (up to 30s)
  for (let i = 0; i < 15; i++) {
    await new Promise(r => setTimeout(r, 2000));
    const resultResp = await fetch(BASE_URL + '/result', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ jobID })
    });
    const resultJson = await resultResp.json();
    if (resultJson.status === 'done') {
      // Verify expected fields
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
    pass "encrypted upload + result (jobID: $JOB_ID)"
    ;;
  FAIL_QUOTE)  fail "could not fetch /quote" ;;
  FAIL_UPLOAD) fail "upload request failed" ;;
  FAIL_JOBID)  fail "no jobID in upload response" ;;
  FAIL_FIELDS) fail "result missing expected fields" ;;
  FAIL_TIMEOUT) fail "result polling timed out" ;;
  FAIL_ERROR*) fail "result returned error: $RESULT" ;;
  FAIL_EXCEPTION*) fail "node exception: $RESULT" ;;
  *) fail "unexpected output: $RESULT" ;;
esac

echo "========================================="
if [ $FAILED -eq 0 ]; then
  echo "All tests passed"
  exit 0
else
  echo "Some tests failed"
  exit 1
fi
