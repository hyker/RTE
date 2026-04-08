# RTE User Manual

## What is the RTE?

The **Restricted and Trusted Environment (RTE)** is a secure analysis service integrated into the Custodes platform. It allows you to submit files for automated security analysis while guaranteeing that **no one — not even the service operator — can access your files or tamper with the results**.

Whether you are a **vendor** submitting your product for evaluation, or an **assessor** reviewing the results, the RTE provides guarantees tailored to your role:

- **For vendors (TOE owners):** Your files stay confidential. They are encrypted on your device before upload and can only be opened inside a verified secure environment. No one — not the service operator, not the cloud provider, not the assessor's organization — can access your raw files outside the enclave. Your intellectual property does not leak.
- **For assessors:** You can trust that the analysis was performed exactly as described. The secure environment's integrity is verified before any upload, the analysis tool runs in hardware-enforced isolation that no one can interfere with, and the results are digitally signed inside the enclave. This guarantees that the findings have not been altered, fabricated, or influenced by any party after the fact.

You do not need to install any software. The entire process runs in your web browser.

### Available analysis tools

| Tool | What it does | Official documentation |
|------|-------------|-------------|
| **cppcheck** | Static analysis tool for C/C++ source code. Detects bugs, undefined behavior, and dangerous coding constructs that compilers normally miss. | [cppcheck.sourceforge.io](https://cppcheck.sourceforge.io/) |
| **checksec** | Inspects a compiled ELF binary and reports which standard exploit-mitigation features (RELRO, stack canary, NX, PIE, Fortify, etc.) are enabled. | [github.com/slimm609/checksec.sh](https://github.com/slimm609/checksec.sh) |
| **dependency-check** | OWASP tool that scans a project's third-party dependencies and reports any that have publicly known vulnerabilities (CVEs). | [owasp.org/www-project-dependency-check](https://owasp.org/www-project-dependency-check/) |
| **binwalk** | Analyzes, reverse-engineers, and extracts the contents of firmware images and other binary blobs (filesystems, compressed archives, embedded executables). | [github.com/ReFirmLabs/binwalk](https://github.com/ReFirmLabs/binwalk) |
| **aeskeyfind** | Scans a binary file or memory dump for AES key schedules, helping locate cryptographic key material left in memory. | [citp.princeton.edu/our-work/memory](https://citp.princeton.edu/our-work/memory/) |

The assessor selects the appropriate tool and parameters when setting up the evaluation in the Custodes platform. As the vendor uploading a TOE, you can review which tool and parameters have been chosen before uploading (see [Step 2](#step-2-review-the-test-configuration)).

---

## How it works — overview

1. You start from the **Custodes platform** and click the button to run an RTE analysis.
2. A new window opens with the **RTE client** — a lightweight web page that handles verification and upload.
3. The RTE client **verifies the secure environment** to confirm it is genuine and untampered.
4. You **review the test configuration**, then **select your file and upload it**.
5. Your file is **encrypted in your browser** and sent to the secure environment.
6. The analysis runs. When finished, **results appear in the Custodes platform**.

The entire upload and verification process typically takes under a minute. The analysis time depends on the tool and file size.

---

## Step-by-step guide

### Getting started

From the Custodes platform, click **"Execute RTE"** (or the equivalent button for your evaluation). A new browser window will open with the RTE client.

<!-- Screenshot: Custodes platform showing the "Execute RTE" button -->

The RTE client window has a green banner at the top confirming that all verification and encryption happens locally in your browser. The tool and parameters for your analysis have been pre-selected by the Custodes platform.

<!-- Screenshot: RTE client window after opening, showing the green banner -->

### Step 0: Review the client code

At the top of the RTE client window, a green banner confirms that all verification and encryption runs locally in your browser. It also provides links to inspect the source code files (`browser-client.js`, `tdx-quote-verifier.js`, `utils.js`) and a link to the full [public repository on GitHub](https://github.com/hyker/RTE).

If you want additional assurance, you have the option to click **"More info"** in the banner to see auditing guidance. You can compare the served files against the public repository to confirm nothing has been modified. The bundled file (`bundle.js`) is produced from the source files using esbuild and can be reproduced from the project source.

<!-- Screenshot: Green banner with "More info" expanded, showing source links and auditing guidance -->

### Step 1: Verify the secure environment

This step confirms that the server you are about to upload to is running inside genuine, tamper-proof hardware, and that its software has not been modified.

Click **"Fetch & Verify Quote"**.

<!-- Screenshot: The "Fetch & Verify Quote" button -->

The client will automatically:

- Contact the server and request a cryptographic attestation.
- Check the attestation against Intel's certificates and revocation lists.
- Confirm the server's identity matches the expected value.

If everything checks out, you will see a green **PASS** box.

<!-- Screenshot: Green PASS result after verification -->

If you see a red **FAIL** box, the client will block you from proceeding — you cannot upload your file. This means the secure environment could not be verified. See [Troubleshooting](#troubleshooting) for details.

> **What is being verified?** The server runs inside an Intel TDX enclave — a hardware-isolated environment that prevents anyone (including the server operator and cloud provider) from reading its memory or modifying its code. The verification proves the enclave is genuine (signed by the CPU hardware) and that the code running inside matches a known-good version. You can expand "More info" in the client for additional technical details.

### Step 2: Review the test configuration

Before uploading, review the test configuration shown on screen. It shows which analysis tool will run and with what parameters.

<!-- Screenshot: Test configuration section showing tool name and parameters -->

The configuration is pre-filled by the Custodes platform. **Take a moment to confirm it matches what you expect.** The RTE guarantees that your file will be processed in a secure, isolated environment — but the specific analysis tool is a third-party program. You should be comfortable with the tool that has been selected.

> **Note:** The RTE does not audit or endorse any specific tool. It provides the secure environment; you (or the Custodes platform on your behalf) choose which tool runs on your data.

### Step 3: Select your file and upload

1. **Drag and drop** your file into the upload area, or click **"Choose File"** to browse.
2. Your file name and size will appear below the drop area. Verify you have selected the correct file.
3. Click **"Upload Test Job"**.

<!-- Screenshot: File selected, ready to upload -->

When you click upload, the following happens automatically in your browser (before anything is sent to the server):

- Your file is **read entirely on your device**.
- It is **encrypted** using a key that only the verified secure environment can use. No one intercepting the data in transit or on the server can read it.
- The encrypted file is then **sent to the server** for processing.

<!-- Screenshot: Upload in progress or completed -->

### Step 4: Wait for results

After a successful upload, the RTE client shows **"Upload complete"**. You can close this window and return to the Custodes platform.

<!-- Screenshot: "Upload complete" confirmation -->

The Custodes platform will automatically retrieve and display the analysis results once processing is finished. Processing time depends on the tool and the size of your file, but most analyses complete within a few minutes.

The results include:

- The **output of the analysis tool** (findings, warnings, etc.).
- A **cryptographic proof** that the results were produced inside the verified secure environment and have not been modified.
- A **hash of your original file**, linking the results to the specific file you uploaded.

---

## What makes this secure?

You do not need to understand the technical details to use the RTE, but here is a summary of the protections in place:

| Protection | What it means for you |
|-----------|----------------------|
| **Hardware isolation** | Your file is processed inside a sealed hardware environment. No one — not the server operator, not the cloud provider — can see or modify what happens inside. |
| **Pre-upload verification** | Before you upload anything, the system cryptographically proves it is genuine and running the expected software. |
| **Browser-side encryption** | Your file is encrypted on your device before it leaves your browser. Only the verified secure environment can decrypt it. |
| **Signed results** | The analysis output is digitally signed inside the secure environment, so tampering with results after the fact is detectable. |

---

## Troubleshooting

**Verification shows FAIL**
The client will block you from proceeding. A verification failure means the secure environment could not be confirmed as genuine. This could be caused by a temporary server issue, a network problem, or (in rare cases) a genuine security concern. Try again after a few minutes. If the problem persists, contact support.

**Verification shows FAIL with an identity mismatch**
This means the software running on the server does not match the expected version. The client will **block you from proceeding** — you cannot override this. This can happen legitimately if the server has been updated but the client has not yet been refreshed to match. Contact the service maintainer to confirm whether a legitimate update occurred. If it was not a planned update, the client will not allow you to proceed.

**Upload section is not visible**
The upload step only appears after verification passes (green PASS). If you do not see the file upload area, complete the verification step first.

**Upload fails with an error**
Check your internet connection and try again. If the error mentions "Tool or parameter not allowed", the test configuration contains a tool or setting the server does not accept — contact the Custodes platform administrator.

**Results are not appearing on the Custodes platform**
Analysis may still be in progress. Most tools complete within a few minutes, but larger files or more complex analyses may take longer. If results have not appeared after 15 minutes, contact support.

---

# THE APPENDIX IS TO BE REMOVED FROM HERE

## Appendix: Running the RTE client from a local file

For users who need maximum assurance over the client code (e.g. for audit purposes), the RTE client can also be run from a local copy on your computer instead of being served from the platform.

1. Download the client files from the [RTE GitHub repository](https://github.com/hyker/RTE).
2. Open `client/index.html` directly in your browser (as a `file://` URL).

Because the local file cannot connect to the server to pre-fetch certain data, you will need to perform one additional step:

1. **Download the CRL file** — The client will show a download link to Intel's Certificate Revocation List. Click it to download the `.der` file.
2. **Upload the CRL file** — Drag and drop (or browse for) the downloaded CRL file into the client.
3. Continue with verification and upload as described in the main guide above.

This method gives you full control over the code running in your browser — you can audit every line before proceeding. The full project source is available at [github.com/hyker/RTE](https://github.com/hyker/RTE).

> **Note:** This method is provided for transparency and audit purposes. For normal use within the Custodes platform, the online version is recommended.



# OLD BELOW

# RTE User Manual

## What is the RTE?

**TODO**
 * add point of view from assesor/vendor
 * integrate with maggioli UI
 * adapt for target audience SME non technical without time to invest. more of a how/to than a technical document

The Restricted and Trusted Environment (RTE) is a service that lets you run security analysis tools on your code or binary files — your **Target of Evaluation (TOE)** — inside a hardware-isolated Intel TDX enclave. The enclave guarantees that:

- **No one can observe your data** — not the server operator, not the cloud provider, not anyone.
- **The analysis environment has not been tampered with** — you can verify this yourself before uploading anything.
- **Results are cryptographically signed** — so you can prove what tool was run, on what input, and what it found.

Your file is encrypted on your device before it ever leaves your browser. The encryption key is derived from the enclave's attested identity, meaning only the verified enclave can decrypt it.

### Available tools

The RTE currently supports the following analysis tools:

| Tool | Purpose |
|------|---------|
| **cppcheck** | Static analysis of C/C++ source code |
| **checksec** | Checks binary security properties (RELRO, stack canary, NX, PIE, etc.) |
| **dependency-check** | OWASP dependency vulnerability scanner |
| **binwalk** | Firmware and binary file analysis |
| **aeskeyfind** | Searches memory dumps or binaries for AES key schedules |

---

## How to access the RTE client

There are two ways to use the RTE client, with different security trade-offs.

### Method A: Online (via browser)

**TODO**
 * rephrase as being entered via main plattform at maggioli
 * 
Open the client in your browser at:

```
https://rteverif.xyz:8445/index.html
```

This is the most convenient method. The server delivers the client code (HTML + JavaScript) to your browser, and everything — verification, encryption, upload — runs locally in your browser.

**Security trade-off:** You are trusting the server at `rteverif.xyz` to deliver unmodified client code. The client includes a transparency notice with links to inspect the source files (`browser-client.js`, `tdx-quote-verifier.js`, `utils.js`) and compare them against the [public repository on GitHub](https://github.com/hyker/RTE). If you do not trust the server to deliver honest code, use Method B instead.

### Method B: Local file (from your desktop)

**TODO**
 * this is not part of the platform we presernt here. we have only one fix method of deployment. put this somewhere else.
 * delete sec urity tradeoff as well

Download the client files from the GitHub repository and open `index.html` directly from your filesystem (as a `file://` URL in your browser).

**Security trade-off:** You have full control over the code running in your browser — you can audit every line before using it. However, this requires you to manually download a Certificate Revocation List (CRL) file from Intel, since the local file cannot fetch it from the server automatically (see Step 1 below). The online version handles this for you.

### Summary of trade-offs

| | Online (Method A) | Local file (Method B) |
|---|---|---|
| **Convenience** | High — just open the URL | Lower — must download files and CRL manually |
| **Code trust** | Trust the server to deliver unmodified code | You control the code entirely |
| **CRL handling** | Automatic (pre-fetched by the server) | Manual download and upload required |

---

## Using the client from Custodes Main Platform

The most common way to reach the RTE client is by being redirected from the **Custodes main platform**. In this flow:

**TODO**
 * redo this with actual images
 * get account by emailing andreas at maggioli
 * andreas.tsigkos@maggioli.gr
 * bullet list below is too technical, end-user don't care about JobID and polling, etc.

1. You click a button on the Custodes platform (Execute RTE).
2. A new window opens with the RTE client at `rteverif.xyz`, pre-configured with the analysis tool and parameters chosen on the platform.
3. You verify the enclave and upload your file (described in the steps below).
4. When the upload completes, the RTE client automatically sends the **Job ID** back to the Custodes platform via a secure browser message (`postMessage`), and you can close the upload window.
5. The Custodes platform uses the Job ID to poll for and display your results.

In this flow, the **test configuration is pre-filled and locked** — you cannot change which tool runs or its parameters, because the platform has already decided that for you. You only need to verify the enclave and upload your file.

## Using the client directly at rteverif.xyz

**TODO**
Remove this part, not applicable to Pilot3.

If you navigate to `https://rteverif.xyz:8445/index.html` yourself (not from the Custodes platform):

1. The test configuration field is **editable** — you choose which tool to run and with what parameters.
2. After upload, the **Job ID is displayed directly** in the client window (since there is no parent platform to receive it).
3. You will need this Job ID to retrieve your results later via the `/result` API endpoint.

---

## Step-by-step guide

**TODO**
 * clean up from all different alternatives
### Step 1: Certificate Revocation List (CRL)

Before verifying the enclave, the client needs Intel's Certificate Revocation List to check that the server's TDX hardware has not been compromised.

**If using the online version:** This step is handled automatically. The server pre-fetches the CRL from Intel, and the client displays its date and SHA-256 hash for transparency. You will see an info box showing when the CRL was last updated. No action is needed — proceed to Step 2.

<!-- Screenshot: CRL info box showing date and SHA-256 hash -->

**If using the local file version:** You must download the CRL manually:

1. Click **"Download CRL File"** — this downloads the CRL directly from Intel's servers (`api.trustedservices.intel.com`).
2. Once downloaded, drag and drop the `.der` file into the upload area (or click to browse).

<!-- Screenshot: CRL download button and upload drop zone -->

### Step 2: Server verification

This is the most important step. It verifies two things:

- **Authenticity:** The server is running inside a genuine Intel TDX enclave (proven by a hardware-rooted digital signature from the CPU, authenticated by Intel).
- **Integrity:** The code inside the enclave matches the expected version (proven by comparing the **RTMR2** value — a cryptographic measurement of the entire boot chain and application code).

The expected RTMR2 value is displayed on screen. This value is embedded in the client and is what guarantees you are talking to a legitimate RTE server.

> **Important:** If you do not trust the source that delivered the client code to you, you should obtain the expected RTMR2 value from an independent trusted channel and compare it with the value shown.

Click **"Fetch & Verify Quote"**. The client will:

1. Request a TDX attestation quote from the server.
2. Verify the quote's cryptographic signature chain against Intel's root certificates and the CRL.
3. Compare the RTMR2 value in the quote against the expected value.
4. Extract the enclave's public key (used for encryption in the next step).

If verification passes, you will see a green **PASS** indicator. If it fails, you will see **FAIL** with a reason — do not proceed if verification fails.

<!-- Screenshot: Verification PASS result -->

### Step 3: Configure the test

> **Note:** If you arrived from the Custodes platform, this section is pre-filled and read-only. Skip to Step 4.

**TODO**
 * even if coming from custodes main platform, dont trust the test paramters, verify them

The test configuration is a JSON object specifying which tool to run and its parameters. For example:

```json
{"tool_name": "cppcheck", "parameters": []}
```

Or with optional parameters:

```json
{"tool_name": "cppcheck", "parameters": [{"param_name": "--enable=", "value": "warning"}]}
```

The available tools and their parameters are listed in the [Available tools](#available-tools) section above.

> **Important:** The RTE guarantees isolation of the analysis environment, but does not control the behavior of the selected tool. You must independently trust the tool you choose to run on your data.

### Step 4: Upload your TOE

1. Drag and drop your file into the upload area, or click to browse.
2. Click **"Upload Test Job"**.

Before uploading, the client:

1. Reads your file entirely in the browser (nothing is sent yet).
2. Encrypts the file and test configuration together using the enclave's public key (ECIES: ECDH + HKDF-SHA256 + AES-128-GCM).
3. Sends the encrypted payload to the server.

The encryption ensures that your data can **only** be decrypted inside the verified enclave. Not even the server operator can read it.

<!-- Screenshot: File selected and Upload Test Job button -->

### Step 5: Receive your Job ID

After a successful upload, you receive a **Job ID** — a random identifier for your analysis job.

- **If opened from the Custodes platform:** The Job ID is sent back to the platform automatically, and the client shows "Upload complete". You can close the window.
- **If opened directly:** The Job ID is displayed prominently on screen. Save it — you will need it to retrieve your results.

<!-- Screenshot: Job ID displayed after upload -->

---

## Retrieving results

If you are using the Custodes platform, results are retrieved and displayed automatically.

If you uploaded directly, you can retrieve results by calling the `/result` endpoint:

```
POST https://rteverif.xyz:8445/result
Content-Type: application/json

{"jobID": "your-job-id-here"}
```

The response will be one of:

| Status | Meaning |
|--------|---------|
| `"status": "pending"` | Analysis is still running. Try again in a few seconds. |
| `"status": "done"` | Analysis is complete. Results are included in the response. |
| `"status": "error", "reason": "not_found"` | No job with that ID exists. |
| `"status": "error", "reason": "expired"` | The job results have expired and been cleaned up. |
| `"status": "error", "reason": "processing_failed"` | The analysis tool encountered an error. |

A completed response includes:

- **`results`** — The output of the analysis tool.
- **`test`** — The tool and parameters that were used.
- **`quote_data`** — A fresh TDX attestation quote, so you can verify the enclave was still intact when results were produced.
- **`crypto_verification_data`** — A digital signature over the results and a SHA-256 hash of your original TOE, binding the results to your specific input.

> **Note:** Results can only be retrieved **once**. After retrieval, they are deleted from the server. Download expired results cannot be recovered.

---

## Security overview

| Layer | What it guarantees |
|-------|-------------------|
| **Intel TDX enclave** | Hardware isolation — no one (including the host OS, hypervisor, or cloud provider) can inspect or modify the enclave's memory. |
| **TDX attestation quote** | Cryptographic proof (signed by the CPU, chained to Intel's root CA) that the enclave is genuine and running expected code. |
| **RTMR2 verification** | The entire boot chain and application code matches a known-good measurement, ensuring nothing has been added, removed, or modified. |
| **CRL check** | Confirms the hardware has not been flagged as compromised by Intel. |
| **ECIES encryption** | Your file is encrypted to the enclave's attested public key before leaving your browser. Only the enclave can decrypt it. |
| **Result signing** | Results are signed by the enclave's private key, proving they were produced inside the verified environment. |

---

## Troubleshooting

**Verification fails with a signature error**
The enclave's TDX quote could not be validated against Intel's certificate chain. This may indicate a problem with the server's hardware attestation. Do not proceed.

**Verification fails with an RTMR2 mismatch**
The code running in the enclave does not match the expected version. This could mean the server has been updated and the client has not, or it could indicate tampering. Do not proceed until you can confirm the expected RTMR2 value from a trusted source.

**TODO**
 * in this case, the client blocks. not possibler to override the RTMR2 mismatch and proceed. The client need to be updated by the service maintainer, if it was a legitimate update; or you should abort if it's a real compromise.

**Upload fails**
Check that verification passed (green PASS) before attempting upload. The enclave's public key is only available after successful verification.

**Job ID shows "not_found"**
The job may never have been created (upload error), or results may have already been retrieved or expired.

**"Tool or parameter not allowed"**
The server only accepts a predefined set of tools and parameter values. Check that your test configuration matches the allowed tools listed above.

