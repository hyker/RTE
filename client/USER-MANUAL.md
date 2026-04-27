# RTE User Manual

## What is the RTE?

The **Restricted and Trusted Environment (RTE)** is a secure analysis service integrated into the CUSTODES platform. It allows you to submit files for automated security analysis while guaranteeing that **no one — not even the service operator — can access your files or tamper with the results**.

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

The assessor selects the appropriate tool and parameters when setting up the evaluation in the CUSTODES platform. As the vendor uploading a TOE, you can review which tool and parameters have been chosen before uploading (see [Step 2](#step-2-review-the-test-configuration)).

---

## How it works — overview

1. You start from the **CUSTODES platform** and click the button "Execute RTE tool" to run an RTE analysis.
2. A new window opens with the **RTE client** — a lightweight web page that handles verification and upload.
3. The RTE client **verifies the secure environment** to confirm it is genuine and untampered.
4. You **review the test configuration**, then **select your file and upload it**.
5. Your file is **encrypted in your browser** and sent to the secure environment.
6. The analysis runs. When finished, **results appear in the CUSTODES platform**.

The entire verification and upload process typically takes under a minute. The upload and analysis time depends on the tool and file size.

---

## Step-by-step guide

### Getting started

From the CUSTODES platform, click **"Execute RTE tool"**. A new browser window will open with the RTE client.

<!-- Screenshot: CUSTODES platform showing the "Execute RTE tool" button -->

### Step 0: Review the client code

At the top of the RTE client window, a green banner confirms that all verification and encryption runs locally in your browser. It also provides links to inspect the source code files (`browser-client.js`, `tdx-quote-verifier.js`, `utils.js`) and a link to the full [public repository on GitHub](https://github.com/hyker/RTE).

You have the option to click **"More info"** in the banner to see auditing guidance. You can compare the served files against the public repository to confirm nothing has been modified. The bundled file (`bundle.js`) is produced from the source files using esbuild and can be reproduced from the project source.

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

The configuration is pre-filled by the CUSTODES platform. **Take a moment to confirm it matches what you expect.** The RTE guarantees that your file will be processed in a secure, isolated environment — but the specific analysis tool is a third-party program. You should be comfortable with the tool that has been selected.

> **Note:** The RTE does not audit the available tools. It provides the secure environment; you (or your choosen assessor through the CUSTODES platform) choose which tool runs on your data.

### Step 3: Select your file and upload

1. **Drag and drop** your file into the upload area, or click **"Choose File"** to browse.
2. Your file name and size will appear below the drop area. Verify you have selected the correct file.
3. Click **"Upload Test Job"**.

<!-- Screenshot: File selected, ready to upload -->

When you click upload, the following happens automatically in your browser (before anything is sent to the server):

- Your file is **read entirely on your device**.
- It is **encrypted** using a key that only the verified secure environment can use. No one intercepting the data in transit or on the server can read it.
- The encrypted file is then **sent to the secure enclave** for processing.

<!-- Screenshot: Upload in progress or completed -->

### Step 4: Wait for results

After a successful upload, the RTE client shows **"Upload complete"**. You can close this window and return to the CUSTODES platform.

<!-- Screenshot: "Upload complete" confirmation -->

The CUSTODES platform will automatically retrieve and display the analysis results once processing is finished. Processing time depends on the tool and the size of your file, but most analyses complete within a few minutes.

The results include:

- The **output of the analysis tool** (findings, warnings, etc.).
- The **tool name** and **parameters** of the test.
- A **cryptographic proof** that the results were produced inside the verified secure environment and have not been modified.
- A **hash of your original file**, linking the results to the specific file you uploaded.

---

## What makes this secure?

You do not need to understand the technical details to use the RTE, but here is a summary of the protections in place:

| Protection | What it means for you |
|-----------|----------------------|
| **Hardware isolation** | Your file is processed inside an isolated hardware environment. No one — not the server operator, not the cloud provider — can see or modify what happens inside. |
| **Pre-upload verification** | Before you upload anything, the system cryptographically proves it is genuine and running the expected software. |
| **Browser-side encryption** | Your file is encrypted on your device before it leaves your browser. Only the verified secure environment can decrypt it. |
| **Signed results** | The analysis output is digitally signed inside the secure environment, so tampering with results after the fact is detectable. |

---

## Troubleshooting

**Verification shows FAIL**
The client will block you from proceeding. A verification failure means the secure environment could not be confirmed as genuine. This could be caused by a temporary server issue, a network problem, or (in rare cases) a genuine security concern. Try again after a few minutes. If the problem persists, contact support.

**Verification shows FAIL with an identity mismatch**
This means the software running on the server does not match the expected version. The client will **block you from proceeding** — you cannot override this. This can happen legitimately if the server has been updated but the client has not yet been refreshed to match. Contact the service maintainer to confirm whether a legitimate update occurred.

**Upload section is not visible**
The upload step only appears after verification passes (green PASS). If you do not see the file upload area, complete the verification step first.

**Upload fails with an error**
Check your internet connection and try again. If the error mentions "Tool or parameter not allowed", the test configuration contains a tool or setting the server does not accept — contact the CUSTODES platform administrator.

**Results are not appearing on the CUSTODES platform**
Analysis may still be in progress. Most tools complete within a few minutes, but larger files or more complex analyses may take longer. If results have not appeared after 15 minutes, contact support.

---

