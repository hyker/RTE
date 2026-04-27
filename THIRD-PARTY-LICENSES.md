# Third-Party Licenses

This file lists the licenses of third-party software distributed with or
bundled into this project. All listed software is compatible with
proprietary use.

---

## Written Offer for GPL Source Code

For any GPL-licensed component distributed in this software (including but
not limited to cppcheck and OpenJDK JRE), Hyker Security AB will provide
the complete corresponding source code on a physical medium customarily
used for software interchange, for a charge no more than the cost of
physically performing source distribution. Send written requests to
joakim.brorsson (at) hyker.se.

This offer is valid for at least three years from the date of distribution
and applies to anyone in possession of this software. The source code
provided will correspond to the exact version distributed; for unmodified
Ubuntu packages, this is equivalent to the source available via
`apt source <package>` on the corresponding Ubuntu release, or from the
upstream project repository.

---

## Tools distributed in the VM image

### cppcheck
- **License:** GPL-3.0
- **Usage:** Installed as an unmodified Ubuntu system package into the
  attested TDX VM image; invoked at runtime as a standalone process. Not
  linked into any proprietary code.
- **Source:** Available from the Ubuntu package repositories
  (`apt source cppcheck`) or https://github.com/danmar/cppcheck

### binwalk
- **License:** MIT
- **Usage:** Installed as an unmodified Ubuntu system package; invoked as a
  standalone process.
- **Source:** Available from the Ubuntu package repositories
  (`apt source binwalk`) or https://github.com/ReFirmLabs/binwalk

### OpenJDK JRE (default-jre-headless)
- **License:** GPL-2.0 with Classpath Exception
- **Usage:** Installed as an unmodified Ubuntu system package into the
  attested TDX VM image; invoked at runtime as the JVM for OWASP
  Dependency-Check. The Classpath Exception permits proprietary programs
  to run on the JVM without triggering copyleft.
- **Source:** Available from the Ubuntu package repositories
  (`apt source openjdk-21-jre-headless`) or https://openjdk.org

### OWASP Dependency-Check
- **License:** Apache-2.0
- **Copyright:** Copyright OWASP Foundation
- **Usage:** Downloaded and installed as a standalone Java application;
  invoked as a separate process.
- **Source:** https://github.com/dependency-check/DependencyCheck

### checksec
- **License:** BSD-3-Clause
- **Copyright:**
  - Copyright (c) 2014-2022, Brian Davis
  - Copyright (c) 2013, Robin David
  - Copyright (c) 2009-2011, Tobias Klein
- **Usage:** Built as a standalone Go binary; invoked as a separate process.
- **Source:** https://github.com/slimm609/checksec.git (submodule)

### aeskeyfind
- **License:** BSD-3-Clause
- **Copyright:**
  - Copyright (c) 2008, Nadia Heninger and Ariel Feldman
  - Copyright (c) 2008, Cameron Rich
  - Copyright (c) 2017, Aidan Thornton
- **Usage:** Built as a standalone C binary; invoked as a separate process.
- **Source:** https://github.com/hyker/aeskeyfind (submodule; fork of
  makomk/aeskeyfind with GCC 13 build fix)

---

## Libraries linked into the custodes binary

### golang.org/x/crypto
- **License:** BSD-3-Clause
- **Copyright:** Copyright (c) 2009 The Go Authors
- **Usage:** Compiled into the custodes Go binary (HKDF).

---

## Libraries linked into the TDX quote generator

### libtdx-attest (Intel TDX DCAP)
- **License:** BSD-3-Clause
- **Copyright:** Copyright (c) Intel Corporation
- **Usage:** Dynamically linked by the quote-generator C binary.

---

## Libraries bundled into the client (bundle.js)

### pkijs
- **License:** BSD-3-Clause
- **Copyright:**
  - Copyright (c) 2014, GlobalSign
  - Copyright (c) 2015-2019, Peculiar Ventures
- **Source:** https://github.com/PeculiarVentures/PKI.js

### asn1js
- **License:** BSD-3-Clause
- **Copyright:**
  - Copyright (c) 2014, GMO GlobalSign
  - Copyright (c) 2015-2022, Peculiar Ventures
- **Source:** https://github.com/PeculiarVentures/asn1.js

### bytestreamjs
- **License:** BSD-3-Clause
- **Copyright:** Copyright (c) 2016-2022, Peculiar Ventures

### @noble/hashes
- **License:** MIT
- **Copyright:** Copyright (c) 2022 Paul Miller
- **Source:** https://github.com/paulmillr/noble-hashes

### pvutils
- **License:** MIT
- **Copyright:** Copyright (c) 2016-2019, Peculiar Ventures

### pvtsutils
- **License:** MIT
- **Copyright:** Copyright (c) 2017-2024, Peculiar Ventures, LLC

### tslib
- **License:** 0BSD
- **Copyright:** Copyright (c) Microsoft Corporation

---

## Build-time only (not distributed)

The following tools are used during the build process but are not included
in the final VM image or client bundle:

- **Canonical TDX scripts** (GPL-3.0) — used to produce the TDX guest base
  image; scripts run during image build (on host and temporarily inside the
  guest); deleted before the image is finalized — not present in the shipped
  image
- **libguestfs / virt-customize** (GPL-2.0+) — used to customize VM images
  on the build host
- **esbuild** (MIT) — JavaScript bundler; output (bundle.js) does not
  contain esbuild code
