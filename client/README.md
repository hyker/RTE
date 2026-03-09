# TDX Quote Verifier - Browser Client

Browser-based client for verifying TDX quotes and uploading test jobs to a trusted execution environment.

## Usage

1. Visit https://150.140.195.209:8444/quote in your browser and accept the certificate warning
2. Open `index.html` in your browser
3. Follow the guided steps:
   - **Step 0**: Establish a VPN tunnel to the RTE (development purposes)
   - **Steps 1 & 2**: Intel Platform CRL is fetched automatically by the VM
   - **Step 3**: Verify the TDX quote (RTMR2 is fetched automatically from the service)
   - **Step 4**: Upload a test job with your TOE (Target of Evaluation) file

## What It Does

- Fetches TDX quote from service at https://150.140.195.209:8444/quote
- Verifies quote signature and certificate chain against Intel root CA
- Checks CRL for certificate revocation
- Validates RTMR2 from the quote (fetched from service in dev mode; should be hardcoded for production)
- Extracts public key from reportData for future signing key verification
- Uploads test jobs to https://150.140.195.209:8444/upload after successful verification

## Build

```bash
npm install
npm run build
```

This produces `bundle.js`, which is the self-contained browser bundle used by `index.html`.

## Hosting via VM (optional)

The `vm/` directory contains scripts to serve the client from a lightweight QEMU VM running nginx.

**Build VM artifacts** (also rebuilds `bundle.js`):

```bash
cd vm && ./build.sh
```

**Start the VM:**

```bash
cd vm && ./boot.sh
```

The client will be available at `https://rteverif.xyz:8445`.

To stop the VM:

```bash
pkill -f 'process=quote-verifier-web'
```

## Integration Demo

`parent.html` demonstrates embedding this client as a sub-page using `window.open()` + `postMessage()`. The job ID is sent back to the parent window after upload.

## Security Note

The service at port 8444 uses a self-signed certificate. For production, implement proper certificate validation.
