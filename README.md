# RTE — Restricted and Trusted Environment

The RTE is a secure analysis service for the CUSTODES platform. Users submit files for automated security analysis inside an Intel TDX confidential VM — no one, including the service operator, can access uploaded files or tamper with results.

## Architecture

The system has two parts:

- **Server** — A dm-verity protected image running inside a TDX confidential VM. Hosts the analysis tools and an HTTPS service for quote retrieval, file upload, and result delivery.
- **Client** — A browser application that verifies the TDX attestation quote, encrypts the upload with ECIES, and submits it to the verified enclave.

## Analysis tools

cppcheck, checksec, OWASP dependency-check, binwalk, aeskeyfind.

## Prerequisites

- Intel TDX-capable hardware (server)
- Node.js (client build)
- Ubuntu cloud image (server base)

## Documentation

See readmes in `server/` and `client/` for build and code details.
See `client/USER-MANUAL.md` for a guide on using a deployed instance.

## SBOM

`./sbom.sh` generates three CycloneDX SBOMs:

- `sbom-rte.cdx.json` — the RTE service: custodes Go modules, the tdx submodule, and (when `server/base-image.raw` is built) the exact Ubuntu package versions inside the image
- `sbom-tools.cdx.json` — the bundled analysis tools and their dependencies: checksec, aeskeyfind, dependency-check (Java), cppcheck, binwalk, and the JRE
- `sbom-client.cdx.json` — the client side: the browser client's npm packages (bundled into `bundle.js`) plus the OS packages inside the client hosting VM (`client/vm/vm-disk-prod.qcow2`: nginx, certbot, …)

Requires [syft](https://github.com/anchore/syft), [cyclonedx-cli](https://github.com/CycloneDX/cyclonedx-cli), and `qemu-img` (to read the qcow2 client VM disk); run `./sbom.sh --help` for options (spec 1.5/1.6, output directory).

## Licenses
This software is source-available under the PolyForm Strict License 1.0.0. The source is published to enable verification of remote attestation measurements. Commercial licenses and other arrangements are available — contact joakim.brorsson (at) hyker.se. Research collaborators may have separate license terms under bilateral agreement.

SPDX-License-Identifier: PolyForm-Strict-1.0.0
   Copyright (c) 2026 Hyker Security AB
