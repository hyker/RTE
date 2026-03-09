import verifyTdxQuote from './tdx-quote-verifier.js';
import { fromBase64, toBase64, toText } from './utils.js';

// Service endpoint
// NOTE: This uses an insecure HTTPS connection for development.
// For production, proper certificate validation should be implemented.
const SERVICE_BASE_URL = 'https://custodesrte.xyz:8444';
const QUOTE_SERVICE_URL = `${SERVICE_BASE_URL}/quote`;
const UPLOAD_SERVICE_URL = `${SERVICE_BASE_URL}/upload`;
const RTMR2_SERVICE_URL = `${SERVICE_BASE_URL}/rtmr2`;

// Global storage for uploaded CRL — pre-load from VM-fetched CRL if available
window.uploadedCRL = window.EMBEDDED_CRL
  ? Uint8Array.from(atob(window.EMBEDDED_CRL), c => c.charCodeAt(0))
  : null;

// Compute and display SHA-256 digest of pre-fetched CRL
if (window.uploadedCRL) {
  crypto.subtle.digest('SHA-256', window.uploadedCRL).then(buf => {
    const hex = Array.from(new Uint8Array(buf)).map(b => b.toString(16).padStart(2, '0')).join('');
    const el = document.getElementById('crlDigest');
    if (el) el.textContent = hex;
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

// Check if RTMR2 matches expected value
function checkRTMR2(rtmr2, expectedHex) {
  if (!rtmr2 || rtmr2.length !== 48) {
    return {
      valid: false,
      message: `Invalid RTMR2 length: ${rtmr2?.length || 0} (expected 48 bytes)`
    };
  }

  if (!expectedHex || expectedHex.length !== 96) {
    return {
      valid: false,
      message: `Invalid expected RTMR2 length: ${expectedHex?.length || 0} (expected 96 hex characters)`
    };
  }

  const actualHex = toHex(rtmr2);
  const normalizedExpected = expectedHex.toUpperCase();

  if (actualHex === normalizedExpected) {
    return {
      valid: true,
      message: 'RTMR2 verified successfully',
      hex: actualHex
    };
  }

  return {
    valid: false,
    message: 'RTMR2 mismatch',
    expected: normalizedExpected,
    actual: actualHex
  };
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

// Fetch expected RTMR2 from service
async function fetchExpectedRTMR2() {
  const response = await fetch(RTMR2_SERVICE_URL, {
    method: 'GET',
    mode: 'cors'
  });

  if (!response.ok) {
    throw new Error(`Failed to fetch expected RTMR2: HTTP ${response.status}`);
  }

  const data = await response.json();

  // Handle different response formats
  if (typeof data === 'string') {
    return data.trim().replace(/\s/g, '');
  }
  if (data.rtmr2) {
    return data.rtmr2.trim().replace(/\s/g, '');
  }
  if (data.value) {
    return data.value.trim().replace(/\s/g, '');
  }

  throw new Error('Unexpected RTMR2 response format');
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

    // Fetch expected RTMR2 from service
    showResult(outputEl, 'loading', 'Fetching expected RTMR2...');
    let expectedRtmr2;
    try {
      expectedRtmr2 = await fetchExpectedRTMR2();
    } catch (err) {
      showResult(outputEl, 'fail', `Could not fetch expected RTMR2: ${err.message}`);
      return;
    }

    if (!expectedRtmr2 || expectedRtmr2.length !== 96) {
      showResult(outputEl, 'fail', `Invalid expected RTMR2 from service (got ${expectedRtmr2?.length || 0} chars, need 96)`);
      return;
    }

    if (!/^[0-9a-fA-F]+$/.test(expectedRtmr2)) {
      showResult(outputEl, 'fail', 'Expected RTMR2 from service contains invalid characters');
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

    // Verify quote
    const result = await verifyTdxQuote(quoteBytes, {});

    if (result instanceof Error) {
      throw result;
    }

    // Check RTMR2 - this is critical for overall verification
    const rtmr2Check = checkRTMR2(result.body.RTMR2, expectedRtmr2);

    if (!rtmr2Check.valid) {
      // RTMR2 mismatch means verification FAILS
      window.verificationState = 'failed';
      showResult(outputEl, 'fail', 'RTMR2 verification failed');
      return;
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
    <div style="margin-top: 16px; text-align: center;">
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

    // Upload to service
    const response = await fetch(UPLOAD_SERVICE_URL, {
      method: 'POST',
      mode: 'cors',
      headers: {
        'Content-Type': 'application/json'
      },
      body: JSON.stringify(payload)
    });

    if (!response.ok) {
      throw new Error(`HTTP error! status: ${response.status}`);
    }

    const data = await response.json();

    const jobId = data.jobID || data.job_id || data.id;
    if (jobId) {
      window.uploadCompleted = true;
      showJobId(outputEl, jobId);
      buttonEl.disabled = true;
      buttonEl.textContent = 'Uploaded';

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
