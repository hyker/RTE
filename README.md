# RTE — Restricted and Trusted Environment

The RTE is a secure analysis service for the CUSTODES platform. Users submit files for automated security analysis inside an Intel TDX confidential VM — no one, including the service operator, can access uploaded files or tamper with results.

## Architecture

The system has two parts:

- **Server** — A dm-verity protected image running inside a TDX confidential VM. Hosts the analysis tools and an HTTPS service for quote retrieval, file upload, and result delivery. The verity root is overlaid with a tmpfs at runtime so the VM can apply security updates; a reboot returns it to the attested image.
- **Client** — A browser application that verifies the TDX attestation quote, encrypts the upload with ECIES, and submits it to the verified enclave. It is served from its own small VM.

## Analysis tools

cppcheck, checksec, OWASP dependency-check, binwalk, aeskeyfind.

---

## Quickstart

### Prerequisites

**Hardware.** An Intel TDX-capable host, set up as a TDX host before anything here will work —
see `server/tdx/README.md` (BIOS settings, kernel, attestation services). **Builds without
`--tdx` currently fail** at the measurement-recording step, so TDX hardware is not optional
today.

**Host packages** (Ubuntu names):

```bash
sudo apt install libguestfs-tools qemu-utils qemu-system-x86 gdisk cryptsetup-bin \
                 cloud-image-utils genisoimage unzip wget curl openssl git make gcc \
                 nodejs npm golang-go
```

Also needed: `sudo` (image and loop-device work), Node.js 18+, and Go 1.25+. Ubuntu 24.04 ships
Go 1.22; the default `GOTOOLCHAIN=auto` downloads the newer toolchain on first build, which
needs network access. `./sbom.sh` additionally needs `syft`, `cyclonedx-cli`, `jq` and
`debugfs`.

**Clone with submodules** — three are required (`server/tdx`, checksec, aeskeyfind) and the
build fails confusingly without them:

```bash
git clone <repo> && cd RTE
git submodule update --init --recursive
```

**Configuration.** Two config files and two secrets files, one pair per VM:

| File | Tracked | Contents |
|---|---|---|
| `server/build-config.sh` | yes | `LE_DOMAIN`, `LE_EMAIL`, `ALLOWED_REFERRER_ORIGIN` |
| `server/secrets.sh` | no | `CF_API_TOKEN` |
| `client/vm/build-config.sh` | yes | `DOMAIN`, `LE_EMAIL` |
| `client/vm/secrets.sh` | no | `CF_API_TOKEN` |

Both domains must be Cloudflare-managed zones with an A record pointing at the host, and both
tokens scoped to `Zone → DNS → Edit`. See "Changing the domain or DNS provider" below.

### Build and run

```bash
./build.sh --dev --tdx      # base image → dm-verity → record measurements → client bundle
./boot.sh dev               # starts the server VM and the client VM
./server/test-endpoints.sh dev
./kill.sh dev
```

Swap `--dev` for `--prod` for a production build. Add `--debug` to keep SSH and console login in
the image for troubleshooting — never for production. Every script takes `--dev`/`--prod` (or
bare `dev`/`prod`) and responds to `--help`; `build.sh --help` lists the pipeline steps, which can
also be run individually — see `server/README.md`.

### Testing

There is no CI, and that is a deliberate position rather than an oversight: the tests need TDX
hardware and a booted VM, so they are run by hand.

```bash
./server/test-endpoints.sh dev     # smoke-tests every endpoint against a running VM
```

It covers `/tools`, `/quote`, `/rtmr2`, `/measurements` (compared against the image's `.meta`),
the referrer gate, and an encrypted upload plus result retrieval for cppcheck, binwalk and
aeskeyfind. checksec and dependency-check are checked only for presence in `/tools` — a full
round-trip for those needs an ELF and a package-manifest fixture respectively. There are no Go
unit tests.

### Ports

| | dev | prod |
|---|---|---|
| Server HTTPS (→ guest :9000) | 9444 | 8444 |
| Server SSH (`--debug` images only) | 2223 | 2222 |
| Client VM HTTPS (→ guest :443) | 9445 | 8445 |
| QEMU monitor (client VM) | 4445 | 4444 |
| TDX guest CID (quote generation on vsock 4050) | 7 | 6 |

---

## Design choices, motivations and gotchas

### Why the build has two steps

`build-base.sh` produces `base-image.raw`: a public, inspectable image with *dummy* verity
parameters. It is not bootable and not bit-reproducible (timestamps differ per run).
`setup-verity.sh` then substitutes the real verity values to produce a bootable image, and that
step *is* deterministic — the same base image always yields the same root hash.

The split exists so there is one artifact anyone can inspect for malicious content, and a second,
mechanically-derived artifact whose measurements anyone can recompute from it.

**The verity salt is hardcoded** in both scripts for the same reason: a random salt would give a
different root hash on every run from the same base. Each deployment can pick its own value, as
long as the two scripts agree.

### What attestation actually covers

dm-verity protects the root filesystem (partitions 1 and 5). The bootloader, ESP and
kernel/initrd (partitions 14–16) sit outside it and are covered by the measurement registers
instead. Contents below were read from the guest's CCEL event log, not assumed:

| Register | Covers | Client policy |
|---|---|---|
| MRTD | TDVF firmware | hard fail |
| RTMR0 | firmware config, Secure Boot variables, boot order | **warn only** |
| RTMR1 | GPT, and every EFI image loaded: shim, GRUB, **and the kernel** | hard fail |
| RTMR2 | MokList variables, the kernel command line, the initrd | hard fail |
| RTMR3 | nothing should extend it | hard fail unless zero |

**Secure Boot is what gets the kernel measured at all.** With it off, GRUB loads the kernel via
the classic Linux boot protocol, never calls firmware `LoadImage`, and the kernel lands in no
register — so a host could swap `/boot/vmlinuz` (outside dm-verity) and still match every pinned
value. Hence `boot.sh` boots `OVMF.tdx.fd`, the only local firmware carrying the MS/Canonical
certificates.

**What prevents turning it back off is MRTD, not a Secure Boot check.** The `SecureBoot` variable
is measured into warn-only RTMR0, so the client never fails on it. Disabling Secure Boot means
booting different firmware, which changes MRTD — a hard fail. **That holds only while the
firmware is a single-file read-only ROM with no variable store; a split CODE/VARS firmware would
reopen it silently.**

RTMR0 stays warn-only because it churns with QEMU/OVMF version and VM memory; hard-failing it
would down every client on any host package upgrade. Pinning MRTD and RTMR1 ties the bundle to
the host's OVMF package and the image's partition table, so changing either means re-recording
and rebuilding the client.

### What the verifier deliberately does not check

Two gaps are known and accepted for this project rather than overlooked:

- **No TCB recency or QE identity evaluation.** The client validates the PCK
  certificate chain to Intel's root and checks the CRL, but it does not fetch Intel's
  TCB info or QE identity, and it does not compare `teeTcbSvn`, `isvSvn`, `mrEnclave` or
  `mrSigner` — those fields are parsed and ignored. A platform running an out-of-date
  TDX module or QE therefore still produces an accepted quote. Closing this means adding
  a PCS/PCCS fetch and a TCB-status policy.
- **No Subresource Integrity on the client bundle.** `index.html` loads `bundle.js` and
  `crl.js` without `integrity` attributes, and there is no CSP. Adding SRI means dropping
  support for opening `index.html` directly from disk, since a single-tag hash cannot be
  maintained across both delivery paths. The bundle is served over TLS from a VM whose
  disk is rebuilt from scratch on every build.

Neither is a reason to distrust a passing verification against a platform you already
trust; both matter if the threat model grows to include a stale or revoked platform.

### Runtime mutability and updates

The verity root is mounted under a tmpfs overlay (`overlayroot`), so the running system is
writable. This was a deliberate trade to let a long-lived VM apply Canonical security updates:

- **Kept:** the host cannot tamper with the base rootfs undetectably (verity still checks every
  read from the lower layer), and the upper layer lives in TDX-protected RAM.
- **Lost:** guest-side immutability, and the verifier's knowledge of the running composite. A
  compromise inside the guest can persist for the life of the boot. A reboot clears it.

**Updates are two-tier.** Kernel and microcode are updated at *image build time*, because they
only take effect on a reboot that returns the VM to the attested image anyway. Userland packages
are updated at *runtime* by unattended-upgrades. The attested claim is therefore "this base
image, plus whatever the Ubuntu archive served since boot" — a verifier can audit the sources,
keys and updater config in the image, but not the resulting binaries.

All tmpfs mounts use `noswap`, so uploaded files, logs and TLS keys never reach disk.

### The `/upload` referrer gate is not authentication

`/upload` checks a client-supplied referrer field against the platform origin baked into the
binary. It is an anti-freeloading speed bump — trivially forgeable, and deliberately so. It never
protects user data: confidentiality comes from the ECIES envelope encrypted to the attested
enclave key. Leave `ALLOWED_REFERRER_ORIGIN` empty to disable it.

### Gotchas

- **`/etc/qgs.conf` must stay on vsock port 4050.** A DCAP upgrade silently replaced this file
  once — no prompt, no `.dpkg-old` — and killed attestation with a symptom identical to the
  quote service being down. It is unmodified again, so it will not prompt next time either.
  Check with `ss -l --vsock` after any DCAP upgrade.
- **Normal boots spend a Let's Encrypt certificate** (5 duplicates per week per hostname).
  `boot.sh --measure-only` serves a self-signed certificate and never contacts LE, so diagnostic
  and measurement boots are free.
- **Rebuild the client VM, don't reboot it.** Booting an existing disk re-serves the webroot
  cloud-init already copied, i.e. a stale bundle with stale measurements.
- **`--debug` images keep SSH, console login and the `tdx` account.** They exist for local
  diagnosis; build production images without the flag. A debug build also has a different
  rootfs, so its RTMR2 differs and a production client bundle refuses to verify against it —
  useful as a backstop, but not something to rely on in place of building correctly.
- **Dev only — accept two certificates, service first.** Prod serves real Let's Encrypt
  certificates on both the client VM and the service, so a normal user sees no warnings at
  all. Dev serves an LE *staging* certificate for the client VM and a self-signed one for
  the service, and both must be accepted. Take the service's `/quote` URL first, directly:
  the page fetches the quote with `fetch()`, and a cross-origin fetch to an untrusted
  certificate fails with no prompt — it surfaces as a network error partway through
  attestation, with nothing pointing at the certificate.
- **Dev only — HSTS can block the client outright.** nginx sends `Strict-Transport-Security`
  with a two-year `max-age` (`client/vm/build.sh`); dev and prod share one hostname and
  differ only by port, and HSTS is keyed on host, ignoring the port. So a browser that has
  opened the prod client pins the name, and dev's staging certificate then becomes a chain
  error HSTS gives you no way to dismiss. Use a private window, or `https://localhost:9445`
  if you are on the host itself. To clear an existing pin: `chrome://net-internals/#hsts`,
  or Firefox's "Forget About This Site".
- **Opening the client directly cannot upload.** The gate compares `document.referrer`,
  which is empty on a direct navigation, so `/upload` answers 402 and the client reports
  only `HTTP error! status: 402`. Attestation and the transparency panel still work. To
  exercise upload outside the platform, use `server/test-endpoints.sh`, or shadow the
  referrer in devtools before uploading:
  `Object.defineProperty(document, 'referrer', {value: '<platform origin>', configurable: true})`.

### Changing the domain or DNS provider

Both VMs have their own domain and their own certificate. Four things to know:

1. **Changing the server domain re-measures the image.** `LE_DOMAIN` is baked into the rootfs
   (`/opt/certbot/certbot.env`), so a new domain changes the verity root hash and RTMR2, and
   every deployed client bundle stops verifying. A domain change means: rebuild, re-record,
   rebuild the client, redeploy.
2. **Only Cloudflare is wired up.** Moving to another DNS provider means changing the certbot
   plugin package (`server/build-base.sh`), the certbot flags and credentials path
   (`server/payload/tls-provision.sh`), the client VM's own certbot invocation
   (`client/vm/build.sh`), and the measure-only escape hatch, which recognises itself by a
   literal `dns_cloudflare_api_token` line.
3. **Failure is silent.** If certbot fails, both VMs fall back to a self-signed certificate and
   keep serving rather than failing loudly. **Always check the issued certificate after a domain
   or DNS change.**
4. A third domain, `ALLOWED_REFERRER_ORIGIN`, is unrelated to DNS — it is the parent platform's
   origin used by the referrer gate above.

---

## SBOM

`./sbom.sh` generates three CycloneDX SBOMs:

- `sbom-rte.cdx.json` — the RTE service: custodes Go modules, the tdx submodule, and (when `server/base-image.raw` is built) the exact Ubuntu package versions inside the image
- `sbom-tools.cdx.json` — the bundled analysis tools and their dependencies: checksec, aeskeyfind, dependency-check (Java), cppcheck, binwalk, and the JRE
- `sbom-client.cdx.json` — the client side: the browser client's npm packages (bundled into `bundle.js`) plus the OS packages inside the client hosting VM (`client/vm/vm-disk-prod.qcow2`: nginx, certbot, …)

Requires [syft](https://github.com/anchore/syft), [cyclonedx-cli](https://github.com/CycloneDX/cyclonedx-cli), and `qemu-img` (to read the qcow2 client VM disk); run `./sbom.sh --help` for options (spec 1.5/1.6, output directory).

## Documentation

- `server/README.md` — image build pipeline, partition layout, payload deployment, known issues
- `client/README.md` — browser client and what it verifies
- `client/vm/README.md` — the client hosting VM
- `client/USER-MANUAL.md` — guide for using a deployed instance

Design rationale lives in this file, not in those.

## Appendix

**How the register contents were established.** The guest exposes the CCEL event log at
`/sys/firmware/acpi/tables/data/CCEL`; parsed as a TCG2 crypto-agile log it names every measured
event. The mapping from the log's index field to registers was verified empirically, by replaying
the log's SHA-384 extends and reproducing a recorded register value byte-for-byte — **it is a flat
index, PCR1 to RTMR0, PCR2 to RTMR1, PCR3 to RTMR2, not the ranged UEFI 2.10 §38 table** that a
reader would otherwise assume applies.

Reading it needs no rebuild and no root on the host: patch `console=tty1` to `init=/bin/sh` inside
`grub.cfg` in place at identical length, boot a scratch copy of the image as a separate TD with
its serial console on a socket, and read the file from the resulting shell. Editing `grub.cfg`
this way is possible precisely because partition 16 is unprotected, which is the same fact the
measurement registers exist to make detectable — and it works: the altered command line changes
RTMR2.

**Runtime RTMR extension is not used.** The attested initial state includes the updater; updates
themselves are not measured.

## Licenses
This software is source-available under the PolyForm Strict License 1.0.0. The source is published to enable verification of remote attestation measurements. Commercial licenses and other arrangements are available — contact joakim.brorsson (at) hyker.se. Research collaborators may have separate license terms under bilateral agreement.

SPDX-License-Identifier: PolyForm-Strict-1.0.0
   Copyright (c) 2026 Hyker Security AB
