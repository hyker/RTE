# TDX Quote Verifier — Browser Client

Browser client that verifies the RTE server's TDX attestation quote, then encrypts and uploads a
TOE (Target of Evaluation) file to the attested enclave.

## Running it

The client is served over HTTPS from its own VM — see [vm/README.md](vm/README.md):

```bash
cd vm && ./build.sh --prod && ./boot.sh --prod   # https://rteverif.xyz:8445
cd vm && ./build.sh --dev  && ./boot.sh --dev    # https://rteverif.xyz:9445
```

The page walks through remote attestation of the server, then offers the test-job upload once
verification passes.

**In dev, accept the service certificate first.** Prod uses real Let's Encrypt certificates
throughout, so there is nothing to accept. Dev does not: the client VM holds a *staging*
certificate and the service a self-signed one. Open the service's quote URL directly
(`https://<service-host>:9444/quote`), accept the warning, and only then load the client — the
page fetches the quote with `fetch()`, and a cross-origin fetch to an untrusted certificate
fails with no prompt, so it looks like a network error during attestation rather than a
certificate problem.

**`npm run build` alone does not produce a usable bundle.** `browser-client.js` carries
placeholders for the service URL and the four expected measurements
(`__SERVICE_URL__`, `__MRTD_SENTINEL__`, `__RTMR0_SENTINEL__`, `__RTMR1_SENTINEL__`,
`__RTMR2_SENTINEL__`); `vm/build.sh` substitutes them from the server's `.meta` file and refuses
to build if any value is missing or malformed. Opening `index.html` against an unsubstituted
bundle will fail verification, by design.

## What it verifies

- Fetches the TDX quote from the server (URL baked in at build time)
- Validates the PCK certificate chain against Intel's root CA, and checks the CRL
- Binds the attestation key to the PCK-signed QE report, then verifies the TD quote signature
  with it — measurements are only compared once this succeeds
- Pins the boot chain against values baked in at build time: MRTD (firmware), RTMR1 (bootloader
  + GPT) and RTMR2 (kernel/initrd/cmdline) are hard failures; RTMR0 (host config) is a warning
  only. RTMR3 must be zero and the TD debug bit must be clear
- Extracts the enclave's public key from the quote's reportData and encrypts the upload to it
  (ECIES: ephemeral P-256 ECDH, HKDF-SHA256, AES-128-GCM)

Upload is gated on verification succeeding; there is no path from a failed quote to an upload.

## Build

```bash
npm install
npm run build      # produces bundle.js — see the caveat above
```

## Integration demo

`parent.html` demonstrates embedding this client as a sub-page via `window.open()` +
`postMessage()`. The job ID is sent back to the parent window after upload.
