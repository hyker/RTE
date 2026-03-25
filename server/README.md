# Verity Image Builder

## Purpose
This repository contains scripts for building a bootable image with dm-verity enabeled to ensure that a file system was booted with integrity, ensuring that no alterations of data relative to a base image has happened.
It is intended to be coupled with secure boot to protect the kernel etc.

## System Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              BUILD PIPELINE                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌──────────────┐      ┌──────────────┐      ┌──────────────┐               │
│  │ Ubuntu Cloud │─────>│ build-base.sh│─────>│base-image.raw│               │
│  │    Image     │      │              │      │ (inspectable)│               │
│  └──────────────┘      └──────┬───────┘      └──────┬───────┘               │
│                               │                      │                       │
│                      ┌────────▼────────┐             │                       │
│                      │  add-payload.sh │             │                       │
│                      │  ┌────────────┐ │             │                       │
│                      │  │  Payload   │ │             │                       │
│                      │  │  Service   │ │             │                       │
│                      │  │  + Tools   │ │             │                       │
│                      │  │  + TDX*    │ │             │                       │
│                      │  └────────────┘ │             │                       │
│                      └─────────────────┘             │                       │
│                                                      │                       │
│                               ┌──────────────────────▼───────┐               │
│                               │      setup-verity.sh         │               │
│                               │  (calculate hash, finalize)  │               │
│                               └──────────────┬───────────────┘               │
│                                              │                               │
│                               ┌──────────────▼───────────────┐               │
│                               │     verity-image.img         │               │
│                               │   (bootable, deterministic)  │               │
│                               └──────────────────────────────┘               │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                                 RUNTIME                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                         QEMU VM (boot.sh)                           │    │
│  │  ┌─────────────────────────────────────────────────────────────┐   │    │
│  │  │              ROOT FS (dm-verity protected, RO)              │   │    │
│  │  │  ┌─────────────────┐  ┌─────────────────────────────────┐  │   │    │
│  │  │  │  Ubuntu 24.04   │  │        /opt/<payload>/          │  │   │    │
│  │  │  │  Base System    │  │  ┌───────────────────────────┐  │  │   │    │
│  │  │  └─────────────────┘  │  │    Payload Service        │  │  │   │    │
│  │  │                       │  │    (user-defined)         │  │  │   │    │
│  │  │                       │  └───────────────────────────┘  │  │   │    │
│  │  │                       │  ┌───────────────────────────┐  │  │   │    │
│  │  │                       │  │    Bundled Tools          │  │  │   │    │
│  │  │                       │  │    (user-defined)         │  │  │   │    │
│  │  │                       │  └───────────────────────────┘  │  │   │    │
│  │  │                       │  ┌───────────────────────────┐  │  │   │    │
│  │  │                       │  │    TDX Quote Generator*   │  │  │   │    │
│  │  │                       │  │    (attestation support)  │  │  │   │    │
│  │  │                       │  └───────────────────────────┘  │  │   │    │
│  │  │                       └─────────────────────────────────┘  │   │    │
│  │  └─────────────────────────────────────────────────────────────┘   │    │
│  │  ┌─────────────────────────────────────────────────────────────┐   │    │
│  │  │                  TMPFS (writable, ephemeral)                │   │    │
│  │  │   /tmp (10G)  /var/log (256M)  /var/tmp (2G)  /run (64M)   │   │    │
│  │  └─────────────────────────────────────────────────────────────┘   │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘

* TDX quote generator only included with --tdx flag
```

### Component Overview

**Build Scripts:**
- **build-base.sh** - Creates base image from Ubuntu cloud image; configures dm-verity partitions, network, tmpfs mounts; calls add-payload.sh; outputs inspectable `base-image.raw`. The upstream base image (TDX qcow2 or plain Ubuntu cloud image) is downloaded/built once and cached locally — subsequent runs reuse the cached file, skipping the download and TDX image build steps.
- **add-payload.sh** - Compiles and installs payload service, tools, certificates, and systemd unit files into the image
- **setup-verity.sh** - Calculates dm-verity root hash from base image, writes hash to grub.cfg, outputs bootable image (`verity-image.img` for staging, `verity-dev-image.img` with `--dev`)
- **boot.sh** - Launches QEMU VM with port forwarding, optional TDX support, and overlay mode for development. Passes the Cloudflare API token to the VM at runtime via QEMU `fw_cfg` (read from `secrets.sh`, never touches the image)

**Runtime Layers:**
- **Root FS (RO)** - dm-verity protected; all binaries, configs, and service code; tamper-evident
- **Tmpfs (RW)** - Ephemeral writable directories for runtime data, logs, and transient processing
- **TDX Quote Generator** - Optional C binary using Intel TDX attestation library for hardware-backed attestation

### Build Flow

```
build-base.sh ──> setup-verity.sh ──> boot.sh
```

1. **build-base.sh** - All filesystem modifications happen here (OS config, payload, tools) because dm-verity hashes the entire root filesystem. Any change after verity setup would invalidate the hash and prevent boot. Outputs `base-image.raw` with placeholder hash values - not yet bootable, but publicly inspectable.

2. **setup-verity.sh** - Separated from build-base to ensure determinism. Given the same `base-image.raw`, this always produces identical hash values and bootable image. This allows a public base image that anyone can verify, while the final image remains reproducible.

3. **boot.sh** - At boot, the kernel uses the root hash (now in grub.cfg) to verify every block read from the root filesystem via dm-verity. Any tampering causes read failures.

**Metadata chain:** `build-base.sh` writes `build.meta` (TDX flag, debug flag, required VM RAM). `setup-verity.sh` reads `build.meta` and writes `<image>.meta` (adds image SHA-256). `boot.sh` reads `<image>.meta` to select the correct QEMU command, allocate RAM, and verify image integrity before boot.

## How to use

**Prerequisites (one-time setup):**

1. Edit `build-config.sh` with your domain details:
   ```bash
   LE_DOMAIN="yourdomain.example.com"
   LE_EMAIL="you@example.com"
   LE_STAGING="true"   # use "false" for production certs
   ```
   **Let's Encrypt rate limits:** Production LE enforces 5 duplicate certificates per week (rolling 7-day window) per hostname. Use `LE_STAGING="true"` during development — staging has no rate limits but produces untrusted certs. Switch to `"false"` only for actual deployments.

2. Create `secrets.sh` (gitignored — never committed):
   ```bash
   CF_API_TOKEN="your-cloudflare-dns-edit-token"
   ```
   **Cloudflare DNS requirement:** The domain in `LE_DOMAIN` must be managed by Cloudflare DNS (free plan is sufficient). If the domain was purchased elsewhere (e.g. Namecheap), point its nameservers to Cloudflare's. The API token must be scoped to `Zone → DNS → Edit` for the specific zone — no broader permissions are needed or recommended. The token is only used at boot time to create and delete a DNS TXT record for the Let's Encrypt DNS-01 challenge; it is never written to the image and never stored inside the VM beyond the duration of `tls-provision.service`.

### Full build (recommended)

Use the top-level wrapper script — it runs all steps in the correct order:

```bash
# From the repo root:
./build.sh --prod|--dev [--tdx] [--debug]
```

This runs: `build-base.sh` → `setup-verity.sh` → `record-rtmr2.sh` → `client/vm/build.sh`

### Individual steps (standalone)

The wrapper calls these in sequence. Each can also be run independently if needed.
All scripts default to dev mode (LE staging) when no mode is given.

```bash
# 1. Build base image (bakes LE_DOMAIN, LE_EMAIL, LE_STAGING into the dm-verity image)
./build-base.sh [--prod|--dev] [--tdx] [--debug]

# 2. Configure dm-verity — writes the image and a .meta file with RTMR2= placeholder
sudo ./setup-verity.sh --prod   # writes verity-image.img
sudo ./setup-verity.sh --dev    # writes verity-dev-image.img

# 3. Record RTMR2 — boots the VM, queries /rtmr2, writes value into .meta, stops VM
#    Requires TDX hardware. Skipped automatically if RTMR2 is already set in .meta.
./record-rtmr2.sh --prod|--dev

# 4. Build client bundle — reads RTMR2 from .meta and injects service URL into bundle.js
cd client/vm && ./build.sh --prod|--dev

# 5. Boot VM for normal use
./boot.sh --prod  # HTTPS 8444, SSH 2222
./boot.sh --dev   # HTTPS 9444, SSH 2223
```

**RTMR2 and the client bundle:** Step 3 records the expected RTMR2 value into `verity-image.img.meta`. Step 4 reads it and bakes it as a constant into `bundle.js` — the client verifier compares the quote's RTMR2 against this hardcoded value rather than trusting the enclave to report its own. If RTMR2 is not yet set in `.meta` (e.g. non-TDX builds), the check is disabled and a warning is printed during the client build.

`boot.sh` verifies the sha256 of the image against `verity-image.img.meta` before booting, ensuring the image and its metadata are in sync. It also passes the Cloudflare API token to the VM via QEMU `fw_cfg` — the token is never written to the image.

## Security model

./build-base.sh takes a standard ubuntu server cloud image, makes alterations to it, and outputs an altered image: base-image.raw.
This image is intended to be a public singleton base image that anbody can inspect to see that it is not maliciously built.
This image has had all the modification needed for verity protection done, but has dummy verity parameters.
Hence it is not bootable.
It is also not deterministic in the sense that things such as time stamps will affect the file system of the image.
It is however inspectable (how to do this is described below).

Given a trusted base-image.raw, one can run ./setup-verity.sh to make a bootable version: verity-image.img.
This script replaces the dummy verity parameters wih the actual values needed.
All runs of ./setup-verity.sh on the same base-image.raw will produce the same verity values and hence the same image. The salt used for the dm-verity hash tree is fixed (hardcoded in both `build-base.sh` and `setup-verity.sh`). This is intentional: a random salt would produce a different root hash on every `setup-verity.sh` run even from the same `base-image.raw`, breaking determinism. Each deployment of this project can use its own fixed salt — the value just needs to be consistent between the two scripts.

The purpose of this two step process is to have a publically verifiable base, and a deterministic (in relation to the base image) bootable image with dm-verity enabled.

The scripts in this repository protects the root filesystem from tampering as follows:
```
Protected by dm-verity:
- Partition 1: Root filesystem with entire OS (/, /usr, /etc, /var, etc.)
- Partition 5: dm-verity hash tree for verifying partition 1

Unprotected:
- Partition 14: BIOS Boot - GRUB bootloader data 
- Partition 15: EFI System - UEFI bootloaders 
- Partition 16: Extended Boot - kernel, initramfs, grub.cfg (contains placeholder dm-verity hash that gets replaced by setup-verity.sh)
```

It is probably also possible to make the build process of the base image deterministic in the future, which would spare us the two step process and the distribution of an altered inspectable image (though still dependent on the security of the base image from ubuntu).

## Tamper proofing unprotected partitions
Since the verity hash is given to the VM as a boot parameter, and the integrity is checked by initramfs at boot, security requires that the integrity of partition 14, 15 and 16 is ensured by other means, e.g. by use of a TPM or TDX.

When using TDX, verifying that RTMR2 matches the expected value (calculated from the image) combined with dm-verity ensures integrity of the entire service.

## How to inspect base image
```
# mount
mkdir -p /tmp/base-image-mount
guestmount -a base-image.raw -m /dev/sda1 --ro /tmp/base-image-mount

# inspection 
# ... check what you need, e.g.:
ls -la /tmp/base-image-mount

# cleanup
guestunmount /tmp/base-image-mount
rm -rf /tmp/base-image-mount

```

## Writable Directories

Root filesystem is read-only (dm-verity). Writable paths use tmpfs (defaults: ~12.5GB total):
- `/tmp` (10G - payload storage), `/var/log` (256M), `/var/lib` (128M), `/var/cache` (64M), `/var/tmp` (2G - dependency-check database)
- Journal stored in `/run` (volatile, 64M max)
- All tmpfs mounts use `noswap`, ensuring runtime data (TOE files, logs, TLS keys) is never written to disk even under memory pressure.

**Tmpfs Configuration:**
Sizes can be customized via environment variables when building:
```bash
TMPFS_SIZE_TMP=20G ./build-base.sh
```
Available variables: `TMPFS_SIZE_TMP`, `TMPFS_SIZE_VAR_LOG`, `TMPFS_SIZE_VAR_LIB`, `TMPFS_SIZE_VAR_CACHE`, `TMPFS_SIZE_VAR_TMP`, `TMPFS_SIZE_JOURNAL`

**VM RAM Requirements:**
Required RAM = total tmpfs + 2GB overhead. Default: ~14.5GB (12.5GB tmpfs + 2GB). Custom tmpfs sizes automatically adjust RAM requirement (shown in build output).

## Disabled Services

**Always disabled:**
- `snapd.service`, `snapd.socket` - Snap package manager
- `sysstat.service` - System statistics
- `systemd-remount-fs.service` - Conflicts with dm-verity read-only root

**Disabled in production mode only** (enabled with `--debug`):
- `ssh.service` - SSH server
- `systemd-logind.service` - Login session management
- `multipathd.service` - Multipath device mapper
- `ModemManager.service` - Modem manager
- `rsyslog.service` - System logging daemon
- `getty@.service` / `serial-getty@.service` - Console login prompts (TTY and serial)
- Root account is locked (`passwd -l root`), making console login impossible even if getty were running. Verifiable: `grep root /etc/shadow` shows `root:!$...`

In `--debug` builds the builder is interactively prompted for a root password at build time (used for SSH access). In production builds a random password is generated and immediately discarded — the account is then locked with `passwd -l`, making the password irrelevant.

## Payload Deployment

**Current Payload:** Custodes - Security testing service with TDX attestation support.

**Deployment Strategy:**
1. Compile static Go binary on host: `cd payload/custodes && make build`
2. Binary embedded in base image via `add-payload.sh` (called from `build-base.sh`)
3. Protected by dm-verity (immutable after boot)
4. Updates require full image rebuild

**Custodes Service:**
- Port: 9000 (HTTPS, forwarded in `boot.sh`)
- Endpoints: `/tools`, `/quote`, `/rtmr2`, `/upload`, `/result`
- Storage: tmpfs at `/var/tmp/custodes/toes` (ephemeral)
- CORS: all origins allowed (`Access-Control-Allow-Origin: *`) including private network access (`Access-Control-Allow-Private-Network: true`), enabling browser-based clients to call the API directly
- Systemd service: `custodes.service` (auto-start)
- Tools: cppcheck, checksec, dependency-check

**TOE Cleanup:**
TOE files are automatically cleaned up to prevent `/var/tmp` from filling up:
- **On result download:** When a client fetches results (status `"done"` or `"error"`), all associated TOE files (`.input`, `.suite`, `.output`, `.failed`) are deleted immediately after the response is sent.
- **Stale file sweeper:** A background goroutine runs every hour and deletes all TOE files older than `MaxTOEAge` (default: 30 days, configured in `cleanup.go`). Stale jobs get a `.expired` marker file left behind so subsequent `/result` polls return `"reason": "expired"` instead of `"not_found"`. Expired markers are cleaned up after double the max age (60 days).
- **`/result` error responses** now include a `reason` field: `"processing_failed"` (tool execution failed), `"expired"` (cleaned up by sweeper), or `"not_found"` (job ID never existed).
- **Upload disk-full:** If writing the TOE to disk fails (e.g. tmpfs full), the upload endpoint returns a JSON error with `"reason": "storage_failed"` and HTTP 500.

**Read-only Adaptations:**
- Binaries/configs: `/opt/custodes/` (read-only, dm-verity protected)
- Runtime data: `/var/tmp/custodes/` (tmpfs, writable)
- dependency-check: Uses `--data /var/tmp/custodes/dependency-check-data` instead of default `/root/.m2/`

**TDX Quote Service (--tdx builds only):**
- Binary: `/opt/tdx-quote-service/quote-generator` (C, uses Intel TDX attestation library)
- Library: `libtdx_attest.so.1` installed via `setup-tdx-config-custom` (enables TDX_SETUP_ATTESTATION=1)
- Returns base64-encoded TDX attestation quotes via `/quote` endpoint
- On non-TDX hardware: returns error (expected)

**TLS Provisioning:**

On every boot, `tls-provision.service` runs before `custodes.service` and:
1. Reads the Cloudflare API token from QEMU `fw_cfg` (passed by `boot.sh`, never in the image)
2. Runs `certbot certonly` with Cloudflare DNS-01 challenge (certbot generates and manages its own TLS key)
3. On success: copies the LE-signed cert and TLS key → `/run/custodes/tls/`
4. On failure (no token, certbot error): generates a self-signed cert and key pair as fallback

`custodes` then loads the cert and key from `/run/custodes/tls/`. `tls-provision.service` has a 5-minute timeout (`TimeoutStartSec=300`); if certbot does not complete within that window (e.g. DNS propagation takes too long), the service fails and the self-signed fallback is used.

**TLS certificate renewal:**

A `tls-renew.timer` (systemd, daily) runs `tls-renew.sh` once per day. The script checks whether the current cert expires within 30 days; if so, it re-runs `tls-provision.sh` and restarts `custodes.service` to pick up the new cert and a fresh enclave signing keypair (~1s downtime). Renewal logs are written to the same `/var/log/tls-provision.log` as initial provisioning.

**Key binding and attestation:**

Two independent keys are generated fresh each boot — no pre-baked keys in the image:
- **Enclave signing keypair**: P256 ECDSA, generated in-memory by custodes at startup, never written to disk. Public key embedded in the TDX quote reportdata field as raw P-256 X‖Y coordinates: 32 bytes X (zero-padded) concatenated with 32 bytes Y (zero-padded), no `0x04` uncompressed-point prefix — 64 bytes total, filling the reportdata field exactly. Used to sign `/result` responses, and also used as the ECDH encryption key for upload payload decryption (see below).
- **TLS key**: P256 ECDSA, managed by certbot in standard `certonly` mode, written to `/run/custodes/tls/key.pem` (tmpfs, ephemeral). Used only for HTTPS transport. Independent of the signing keypair.

**TODO — key separation:** The enclave signing keypair currently serves a dual purpose: ECDSA signing of `/result` responses, and ECDH decryption of encrypted `/upload` payloads. Using the same key for both signing and key agreement is a cryptographic anti-pattern (separation of concerns). A future iteration should generate two distinct P-256 keypairs at startup — one for signing, one for ECDH — and publish both in the TDX quote reportdata (or an alternative attestation field).

A verifier can confirm via the quote that result signatures belong to this specific attested boot. The attested public key is the enclave signing key — not the TLS key.
- `LE_DOMAIN`, `LE_EMAIL`, and `LE_STAGING` are baked into the dm-verity image (`/opt/certbot/certbot.env`) and thus covered by RTMR2 — a verifier can confirm which domain is being certified and whether staging was used
- The Cloudflare API token is a deployment secret: it controls DNS API access for the issuance challenge but cannot change the domain, the code, or custodes behaviour

**Test:**
```bash
# dev VM (boot.sh --dev forwards host:9001 → guest:9000)
curl -k https://localhost:9001/tools   # List tools
curl -k https://localhost:9001/quote   # Generate TDX quote
curl -k https://localhost:9001/rtmr2   # Get RTMR2 value

# staging VM (boot.sh --staging forwards host:8444 → guest:9000)
curl -k https://localhost:8444/tools
```

`test-endpoints.sh` provides an automated smoke test hitting all four endpoints in sequence:
```bash
./test-endpoints.sh dev      # tests against port 9001
./test-endpoints.sh staging  # tests against port 8444
```

**Verifying RTMR2:**
After verifying the image, obtain the expected RTMR2 value:
- Infrastructure owners: `curl -k https://localhost:9001/rtmr2` (dev) or `curl -k https://localhost:8444/rtmr2` (staging)
- Third-party verifiers: use [tdx-measure](https://github.com/virtee/tdx-measure) to calculate RTMR values directly from the image

## Planned Tools

All tools must run entirely within the RTE — no sending data to external services or depending on cloud compute. Syncing a vulnerability database from an upstream source is acceptable.

**Current tools:** cppcheck, checksec, dependency-check

### Should be installed

| Tool | Purpose |
|------|---------|
| [binwalk](https://github.com/ReFirmLabs/binwalk) | Firmware analysis — extract and analyze embedded file systems, compressed archives, and binary blobs |
| [AESKeyFinder](https://github.com/makomk/aeskeyfind) | Scan memory dumps or binary images for AES key schedules |
| [AFL++](https://github.com/AFLplusplus/AFLplusplus) | Coverage-guided fuzzing framework for compiled binaries and source code |

### Might be installed

| Tool | Purpose | Notes |
|------|---------|-------|
| [SonarQube CE](https://www.sonarsource.com/open-source-editions/sonarqube-community-edition/) | Multi-language static analysis (bugs, code smells, security hotspots) | Self-hosted; heavyweight (JVM + embedded DB, ~2GB+ RAM). May strain tmpfs/RAM budget |
| [EMBA](https://github.com/e-m-b-a/emba) | Embedded Linux firmware security analysis | Has an optional AI mode that calls external APIs — must be disabled |
| [Semgrep OSS](https://github.com/semgrep/semgrep) | Lightweight, pattern-based static analysis for many languages | Must use OSS engine only — Semgrep Cloud/App sends code to external servers |
| [pgBadger](https://github.com/darold/pgbadger) | PostgreSQL log analyzer — performance and error reporting | Niche; useful if TOEs include PG logs |

### Can be installed upon request

| Tool | Purpose |
|------|---------|
| [Trivy](https://github.com/aquasecurity/trivy) | Vulnerability and misconfiguration scanner for containers, filesystems, SBOMs |
| [Bandit](https://github.com/PyCQA/bandit) | Python-specific security linter |
| [SpotBugs / FindSecBugs](https://github.com/find-sec-bugs/find-sec-bugs) | Java bytecode security analysis |
| [Flawfinder](https://github.com/david-a-wheeler/flawfinder) | C/C++ source security scanner (complements cppcheck) |
| [Grype](https://github.com/anchore/grype) | Vulnerability scanner for SBOMs and filesystem artifacts |
| [Syft](https://github.com/anchore/syft) | SBOM generator (pairs with Grype/Trivy) |
| [PMD](https://github.com/pmd/pmd) | Java/Apex/JS source code analyzer |
| [ESLint + security plugin](https://github.com/eslint/eslint) | JavaScript/TypeScript security linting |

## Known Issues

* **Non-TDX builds are currently broken.** The build pipeline and custodes service assume TDX hardware is available (quote generator, RTMR2 recording). Builds without `--tdx` will fail at the RTMR2 recording step and the service may not start correctly. Use `--tdx` on TDX-capable hardware for now.

## Notes about current state and next steps

 * Make debug version note that very clearly (in output? or some other fashion)
 * move "add payload" scrtipt into function of build base instead.
 * move different parts of build base into separate functions
 * ~~**Custodes TOE cleanup:** Done. See "TOE Cleanup" section below.~~
