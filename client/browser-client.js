import verifyTdxQuote from './tdx-quote-verifier.js';
import { fromBase64, toBase64, toText } from './utils.js';

// Service endpoint — injected at build time by client/vm/build.sh
const SERVICE_BASE_URL = '__SERVICE_URL__';
const QUOTE_SERVICE_URL = `${SERVICE_BASE_URL}/quote`;
const UPLOAD_SERVICE_URL = `${SERVICE_BASE_URL}/upload`;

// Expected RTMR2 — injected at build time from server .meta file
const EXPECTED_RTMR2 = "__RTMR2_SENTINEL__";

// Display expected RTMR2 in the UI
const rtmr2El = document.getElementById('expectedRtmr2');
if (rtmr2El) {
  rtmr2El.textContent = EXPECTED_RTMR2;
}

// Global storage for uploaded CRLs — pre-load from VM-fetched CRLs if available
window.uploadedCRL = window.EMBEDDED_CRL
  ? Uint8Array.from(atob(window.EMBEDDED_CRL), c => c.charCodeAt(0))
  : null;
window.uploadedRootCRL = window.EMBEDDED_ROOT_CRL
  ? Uint8Array.from(atob(window.EMBEDDED_ROOT_CRL), c => c.charCodeAt(0))
  : null;

// Display CRL SHA-256 hash in the UI
if (window.uploadedCRL) {
  crypto.subtle.digest('SHA-256', window.uploadedCRL).then(hash => {
    const hashEl = document.getElementById('crlHash');
    if (hashEl) {
      hashEl.textContent = Array.from(new Uint8Array(hash))
        .map(b => b.toString(16).padStart(2, '0'))
        .join('')
        .toUpperCase();
    }
  });
}

// Global storage for extracted public key
window.extractedPublicKey = null;

// Track verification state: 'pending', 'passed', 'failed'
window.verificationState = 'pending';

// Track if upload has been completed
window.uploadCompleted = false;

// Helper to convert Uint8Array to hex string
function toHex(bytes) {
  return Array.from(bytes)
    .map(b => b.toString(16).padStart(2, '0'))
    .join('')
    .toUpperCase();
}

// Extract public key from reportData
// The reportData field is 64 bytes and contains the public key
function extractPublicKey(reportData) {
  if (!reportData || reportData.length !== 64) {
    return {
      success: false,
      message: `Invalid reportData length: ${reportData?.length || 0} (expected 64 bytes)`
    };
  }

  // Return the raw public key bytes
  return {
    success: true,
    publicKey: new Uint8Array(reportData),
    hex: toHex(reportData),
    message: 'Public key extracted from reportData'
  };
}

// Load CRL from file input
async function loadCRL() {
  const fileInput = document.getElementById('crlFile');
  if (!fileInput.files || fileInput.files.length === 0) {
    return null;
  }

  const file = fileInput.files[0];
  const arrayBuffer = await file.arrayBuffer();
  return new Uint8Array(arrayBuffer);
}

// Show result box with pass/fail status
function showResult(outputEl, status, message) {
  if (status === 'loading') {
    outputEl.innerHTML = `<div class="result-box loading">${message}</div>`;
  } else if (status === 'pass') {
    outputEl.innerHTML = `<div class="result-box pass">PASS</div>`;
  } else {
    outputEl.innerHTML = `<div class="result-box fail">FAIL<br><small style="font-weight:normal;font-size:14px;margin-top:8px;display:block;">${message}</small></div>`;
  }
}

// Main function to fetch and verify quote
export async function fetchAndVerifyQuote() {
  const outputEl = document.getElementById('output');
  const buttonEl = document.getElementById('verifyButton');

  try {
    buttonEl.disabled = true;
    window.verificationState = 'pending';

    // Load CRL — use pre-fetched CRL if available, otherwise load from file input
    showResult(outputEl, 'loading', 'Loading CRL...');
    if (!window.uploadedCRL) {
      window.uploadedCRL = await loadCRL();
    }
    if (!window.uploadedCRL) {
      showResult(outputEl, 'fail', 'Please upload the CRL file first');
      return;
    }

    showResult(outputEl, 'loading', 'Fetching quote from service...');

    // Fetch quote from service
    const response = await fetch(QUOTE_SERVICE_URL, {
      method: 'POST',
      mode: 'cors'
    });

    if (!response.ok) {
      throw new Error(`HTTP error! status: ${response.status}`);
    }

    const data = await response.json();
    showResult(outputEl, 'loading', 'Verifying quote...');

    // Decode base64 quote
    const quoteBytes = fromBase64(data.quote_data);
    if (quoteBytes.length === 0) {
      throw new Error('Failed to decode quote data');
    }

    // Verify quote — RTMR2 check is performed inside the verifier
    const result = await verifyTdxQuote(quoteBytes, {
      expectedRTMR2: EXPECTED_RTMR2
    });

    if (result instanceof Error) {
      throw result;
    }

    // Extract public key from reportData (for future signing key verification)
    const publicKeyResult = extractPublicKey(result.body.reportData);
    if (publicKeyResult.success) {
      window.extractedPublicKey = publicKeyResult.publicKey;
    }

    // All checks passed
    window.verificationState = 'passed';
    showResult(outputEl, 'pass', '');

    // Advance to step 4
    if (window.advanceToStep) {
      window.advanceToStep(4);
    }

  } catch (error) {
    window.verificationState = 'failed';
    showResult(outputEl, 'fail', error.message);
    console.error('Verification failed:', error);
  } finally {
    buttonEl.disabled = false;
  }
}

// Infer file format from extension
function inferFormat(filename) {
  const ext = filename.split('.').pop().toLowerCase();
  const formatMap = {
    'c': 'c',
    'h': 'c',
    'cpp': 'cpp',
    'cc': 'cpp',
    'cxx': 'cpp',
    'hpp': 'cpp',
    'py': 'python',
    'js': 'javascript',
    'ts': 'typescript',
    'java': 'java',
    'rs': 'rust',
    'go': 'go'
  };
  return formatMap[ext] || ext;
}

// Show job ID result
function showJobId(outputEl, jobId) {
  outputEl.innerHTML = `
    <div class="job-id-box">
      <div class="job-id-label">Job ID</div>
      <div class="job-id-value">${jobId}</div>
    </div>
    <div style="margin-top: 10px; text-align: center;">
      <button class="btn btn-secondary" onclick="window.close()">Close Window</button>
    </div>
  `;
}

// Show upload error
function showUploadError(outputEl, message) {
  outputEl.innerHTML = `<div class="error-box">${message}</div>`;
}

// Show upload loading
function showUploadLoading(outputEl, message) {
  outputEl.innerHTML = `<div class="result-box loading">${message}</div>`;
}

// Encrypt payload bytes using ECIES: ECDH (ephemeral P-256) + HKDF-SHA256 + AES-128-GCM.
// serverPubKey64: 64-byte Uint8Array, raw X||Y coordinates of the attested enclave public key.
// Returns the encrypted envelope object ready to JSON-stringify and POST.
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

// Upload test job to the service
export async function uploadTestJob() {
  const outputEl = document.getElementById('uploadOutput');
  const buttonEl = document.getElementById('uploadButton');
  const statusEl = document.getElementById('uploadStatus');

  if (window.uploadCompleted) {
    return;
  }

  if (window.verificationState !== 'passed') {
    showUploadError(outputEl, 'Quote verification must pass before uploading');
    return;
  }

  try {
    buttonEl.disabled = true;
    if (statusEl) statusEl.textContent = '';
    showUploadLoading(outputEl, 'Preparing upload...');

    // Get test configuration
    const testConfigInput = document.getElementById('testConfig');
    let testConfig;
    try {
      testConfig = JSON.parse(testConfigInput.value);
    } catch (e) {
      showUploadError(outputEl, 'Invalid test configuration JSON');
      return;
    }

    if (!testConfig.tool_name) {
      showUploadError(outputEl, 'Test configuration must include "tool_name"');
      return;
    }

    // Get TOE file
    const toeFileInput = document.getElementById('toeFile');
    if (!toeFileInput.files || toeFileInput.files.length === 0) {
      showUploadError(outputEl, 'Please select a TOE file to upload');
      return;
    }

    const toeFile = toeFileInput.files[0];
    const format = inferFormat(toeFile.name);
    showUploadLoading(outputEl, 'Uploading...');

    const arrayBuffer = await toeFile.arrayBuffer();
    const base64Content = toBase64(new Uint8Array(arrayBuffer));

    // Build request payload
    const payload = {
      toe: {
        format: format,
        base64_encoded_toe: base64Content
      },
      test: {
        tool_name: testConfig.tool_name,
        parameters: testConfig.parameters || []
      }
    };

    // Encrypt payload to the attested enclave public key before sending
    if (!window.extractedPublicKey) {
      showUploadError(outputEl, 'Enclave public key not available — quote verification must pass first');
      return;
    }
    const plaintextBytes = new TextEncoder().encode(JSON.stringify(payload));
    const encryptedBody = await encryptPayload(window.extractedPublicKey, plaintextBytes);

    const response = await fetch(UPLOAD_SERVICE_URL, {
      method: 'POST',
      mode: 'cors',
      headers: {
        'Content-Type': 'application/json'
      },
      body: JSON.stringify(encryptedBody)
    });

    if (!response.ok) {
      throw new Error(`HTTP error! status: ${response.status}`);
    }

    const data = await response.json();

    const jobId = data.jobID || data.job_id || data.id;
    if (jobId) {
      window.uploadCompleted = true;
      buttonEl.disabled = true;
      buttonEl.textContent = 'Uploaded';

      if (window.opener) {
        // Opened as popup — parent receives job ID via postMessage
        outputEl.innerHTML = '<div class="result-box pass">Upload complete</div>';
      } else {
        // Standalone — show job ID directly
        showJobId(outputEl, jobId);
      }

      // Notify parent window if opened as popup
      if (window.opener) {
        window.opener.postMessage({ type: 'TOE_UPLOAD_COMPLETE', jobId }, '*');
      }
    } else {
      showUploadError(outputEl, 'Upload succeeded but no job ID was returned');
      buttonEl.disabled = false;
    }

  } catch (error) {
    showUploadError(outputEl, error.message);
    console.error('Upload failed:', error);
    buttonEl.disabled = false;
  }
}

// Expose to global scope for HTML button onclick
window.fetchAndVerifyQuote = fetchAndVerifyQuote;
window.uploadTestJob = uploadTestJob;
