# Verity Image Builder

## Purpose
Scripts for building a bootable image whose root filesystem is dm-verity protected, so a verifier
can establish that it booted from a known base image with no alterations.

dm-verity alone covers only the root filesystem. The kernel, initrd and bootloader live on
partitions outside it, so they are covered by the TDX measurement registers instead — see
"Tamper proofing unprotected partitions" below, and the design section in the top-level README.

**Secure Boot is required for that coverage to be complete.** `boot.sh` boots
`/usr/share/ovmf/OVMF.tdx.fd`, the only local firmware carrying the Microsoft/Canonical
certificates. Booting `OVMF.fd` instead disables Secure Boot, and the kernel then ends up
measured into no register at all — see the top-level README for why.

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
│  │  │      ROOT FS (dm-verity lower + tmpfs overlay, see below)   │   │    │
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
- **build-base.sh** - Creates base image from Ubuntu cloud image; configures dm-verity partitions, network, tmpfs mounts; calls add-payload.sh; outputs inspectable `base-image.raw`. The upstream base image (TDX qcow2 or plain Ubuntu cloud image) is downloaded/built once and cached locally — subsequent runs reuse the cached file, skipping the download and TDX image build steps. Because that cached file is a snapshot that ages, every build now runs an `apt-get dist-upgrade` over it first, so each image starts fully patched. This is the only way the kernel gets updated — a reboot returns the VM to this image, so runtime updates can never change it. When the upgrade does pull something in, the root hash changes and so do the measurements — RTMR2 via the command line, and RTMR1 too if the kernel itself moved — so re-record and rebuild the client.
- **add-payload.sh** - Compiles and installs payload service, tools, certificates, and systemd unit files into the image
- **setup-verity.sh** - Calculates dm-verity root hash from base image, writes hash to grub.cfg, outputs bootable image (`verity-image.img` for staging, `verity-dev-image.img` with `--dev`)
- **boot.sh** - Launches QEMU VM with port forwarding, optional TDX support, and overlay mode for development. Passes the Cloudflare API token to the VM at runtime via QEMU `fw_cfg` (read from `secrets.sh`, never touches the image)

**Runtime Layers:**
- **Root FS** - dm-verity protected lower layer (all binaries, configs and service code, tamper-evident) under a tmpfs overlay that makes it writable at runtime; a reboot discards the overlay
- **Tmpfs (RW)** - Ephemeral writable directories for runtime data, logs, and transient processing
- **TDX Quote Generator** - Optional C binary using Intel TDX attestation library for hardware-backed attestation

### Build Flow

```
build-base.sh ──> setup-verity.sh ──> boot.sh
```

1. **build-base.sh** - All filesystem modifications happen here (OS config, payload, tools) because dm-verity hashes the entire root filesystem. Any change after verity setup would invalidate the hash and prevent boot. Outputs `base-image.raw` with placeholder hash values - not yet bootable, but publicly inspectable.

2. **setup-verity.sh** - Separated from build-base to ensure determinism. Given the same `base-image.raw`, this always produces identical hash values and bootable image. This allows a public base image that anyone can verify, while the final image remains reproducible.

3. **boot.sh** - At boot, the kernel uses the root hash (now in grub.cfg) to verify every block read from the root filesystem via dm-verity. Any tampering causes read failures.

**Metadata chain:** `build-base.sh` writes `build.meta` (TDX flag, debug flag, required VM RAM). `setup-verity.sh` reads `build.meta` and writes `<image>.meta` (TDX, debug, RAM, RTMR2 placeholder). `record-rtmr2.sh` fills in the RTMR2 value. `boot.sh` reads `<image>.meta` to select the correct QEMU command and allocate RAM.

## How to use

**Prerequisites (one-time setup):**

1. Edit `build-config.sh` with your domain details:
   ```bash
   LE_DOMAIN="yourdomain.example.com"
   LE_EMAIL="you@example.com"
   ```
   **Let's Encrypt rate limits:** production LE enforces 5 duplicate certificates per week (rolling 7-day window) per hostname. Staging certificates are untrusted but unlimited, and are selected automatically by `--dev`; `--prod` uses production LE. This is derived from the build mode (`build-base.sh`), not set here. Measurement-only boots cost no certificate at all — see `boot.sh --measure-only`.

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

**Measurements and the client bundle:** Step 3 records `MRTD`, `RTMR0`, `RTMR1` and `RTMR2` into `verity-image.img.meta` (via `/measurements`; the older RTMR2-only `/rtmr2` endpoint still works). Step 4 reads them and bakes them into `bundle.js` — the client compares the quote against these hardcoded values rather than trusting the enclave to report its own. The build fails if any is missing or malformed.

MRTD, RTMR1 and RTMR2 are hard failures. RTMR0 is advisory: it covers host firmware configuration and legitimately changes with the host's QEMU/OVMF version and the VM's RAM size, so a mismatch is shown as a warning rather than taking the service down for every client. RTMR3 (must be zero) and the TD debug bit (must be clear) are invariants and so are not recorded.

Because MRTD and RTMR1 are now pinned, **upgrading the host's OVMF package or changing the ESP contents requires re-recording and a client rebuild**, exactly as a rootfs change does today.

`record-rtmr2.sh` boots with `boot.sh --measure-only`, which passes a sentinel in place of the Cloudflare token so the guest serves a self-signed certificate and never contacts Let's Encrypt. Measurement boots therefore cost no certificate (LE allows only 5 duplicates per week).

`boot.sh` reads `verity-image.img.meta` for VM configuration (TDX mode, RAM size). Image integrity is ensured at runtime by dm-verity (root filesystem) and by the pinned measurements above: MRTD covers the firmware, RTMR1 the bootloader images and the kernel, RTMR2 the command line and initrd. The Cloudflare API token is passed to the VM via QEMU `fw_cfg` — never written to the image.

## Security model

The rationale for the two-step build, the fixed verity salt, and what the TDX measurement
registers cover is in the **top-level README** ("Design choices, motivations and gotchas").
This section covers only the mechanics.

`build-base.sh` turns a stock Ubuntu cloud image into `base-image.raw` — verity-ready but with
dummy parameters, so not bootable. `setup-verity.sh` substitutes the real values to produce
`verity-image.img`, deterministically: the same base image always yields the same root hash.

```
Protected by dm-verity:
- Partition 1: Root filesystem with entire OS (/, /usr, /etc, /var, etc.)
- Partition 5: dm-verity hash tree for verifying partition 1

Unprotected (covered by the TDX measurement registers instead):
- Partition 14: BIOS Boot - GRUB bootloader data
- Partition 15: EFI System - UEFI bootloaders
- Partition 16: Extended Boot - kernel, initramfs, grub.cfg (contains a placeholder
                dm-verity hash that setup-verity.sh replaces)
```

The verity root hash reaches the VM as a kernel command-line parameter and is checked by
initramfs at boot, which is why the integrity of partitions 14–16 has to come from TDX (or a TPM)
rather than from verity itself.

Making the base-image build reproducible would remove the need for the two-step process and for
distributing an inspectable intermediate — still subject to trusting Ubuntu's base image.

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

`overlayroot` puts a tmpfs overlay over the dm-verity root at boot, so apt and dpkg can write.
The verity device underneath is never remounted read-write. `/var/lib` and `/var/cache` used to be
bare tmpfs, which hid `/var/lib/dpkg` and left apt inert; they now come from the overlay.
Kernel and microcode are excluded from runtime updates in
`/etc/apt/apt.conf.d/99zz-rte-unattended-upgrades`.

**The security tradeoff this represents, and the two-tier update model, are in the top-level
README** — read that before changing anything here.

Writable paths still on their own tmpfs (defaults: ~12.3GB total):
- `/tmp` (10G - payload storage), `/var/log` (256M), `/var/tmp` (2G - dependency-check database)
- Journal stored in `/run` (volatile, 64M max)
- All tmpfs mounts use `noswap`, ensuring runtime data (TOE files, logs, TLS keys) is never written to disk even under memory pressure.

**Tmpfs Configuration:**
Sizes can be customized via environment variables when building:
```bash
TMPFS_SIZE_TMP=20G ./build-base.sh
```
Available variables: `TMPFS_SIZE_TMP`, `TMPFS_SIZE_VAR_LOG`, `TMPFS_SIZE_VAR_TMP`, `TMPFS_SIZE_JOURNAL`, `TMPFS_SIZE_OVERLAY`. Note `TMPFS_SIZE_OVERLAY` only sizes the VM's RAM — overlayroot drops any `size=`, so the overlay itself can grow to the kernel default of half of RAM.

**VM RAM Requirements:**
Required RAM = total tmpfs + 2GB overhead. Default: ~16.3GB (12.3GB of tmpfs mounts, plus the 2GB overlay budget, plus 2GB) — i.e. `VM_MEMORY=16704`. Custom tmpfs sizes automatically adjust RAM requirement (shown in build output).

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
- Tools: cppcheck, checksec, dependency-check, binwalk, aeskeyfind

**TOE Cleanup:**
TOE files are automatically cleaned up to prevent `/var/tmp` from filling up:
- **On result download:** When a client fetches results (status `"done"` or `"error"`), all associated TOE files (`.input`, `.suite`, `.output`, `.failed`) are deleted immediately after the response is sent.
- **Stale file sweeper:** A background goroutine runs every hour and deletes all TOE files older than `MaxTOEAge` (default: 30 days, configured in `cleanup.go`). Stale jobs get a `.expired` marker file left behind so subsequent `/result` polls return `"reason": "expired"` instead of `"not_found"`. Expired markers are cleaned up after double the max age (60 days).
- **`/result` error responses** now include a `reason` field: `"processing_failed"` (tool execution failed), `"expired"` (cleaned up by sweeper), or `"not_found"` (job ID never existed or already downloaded).
- **Upload disk-full:** If writing the TOE to disk fails (e.g. tmpfs full), the upload endpoint returns a JSON error with `"reason": "storage_failed"` and HTTP 500.

**Adaptations for a non-writable base:**
- Binaries/configs: `/opt/custodes/` (dm-verity protected; writable only via the runtime overlay, which a reboot discards)
- Runtime data: `/var/tmp/custodes/` (tmpfs, writable)
- dependency-check: Uses `--data /var/tmp/custodes/dependency-check-data` instead of default `/root/.m2/`
- aeskeyfind: Built with `-O1 -fno-strict-aliasing` — upstream Makefile uses `-O4`, which triggers a GCC 13 strict-aliasing miscompilation that silently breaks key schedule detection

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
# dev VM  (boot.sh --dev  forwards host:9444 → guest:9000)
# prod VM (boot.sh --prod forwards host:8444 → guest:9000)
curl -k https://localhost:9444/tools          # List tools
curl -k https://localhost:9444/quote          # Generate TDX quote
curl -k https://localhost:9444/measurements   # All pinned measurements
curl -k https://localhost:9444/rtmr2          # RTMR2 alone
```

`test-endpoints.sh` runs an automated smoke test over every endpoint:
```bash
./test-endpoints.sh dev      # port 9444
./test-endpoints.sh prod     # port 8444
```

**Verifying RTMR2:**
After verifying the image, obtain the expected RTMR2 value:
- Infrastructure owners: `curl -k https://localhost:9444/rtmr2` (dev) or `curl -k https://localhost:8444/rtmr2` (prod)
- Third-party verifiers: use [tdx-measure](https://github.com/virtee/tdx-measure) to calculate RTMR values directly from the image

## Planned Tools

All tools must run entirely within the RTE — no sending data to external services or depending on cloud compute. Syncing a vulnerability database from an upstream source is acceptable.

**Current tools:** cppcheck, checksec, dependency-check, binwalk, aeskeyfind

### Should be installed

| Tool | Purpose |
|------|---------|
| ~~[binwalk](https://github.com/ReFirmLabs/binwalk)~~ | ~~Firmware analysis~~ — **done** |
| ~~[AESKeyFinder](https://github.com/makomk/aeskeyfind)~~ | ~~Scan memory dumps or binary images for AES key schedules~~ — **done** |
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

* **`not_found` conflates "never existed" and "already downloaded".** After a result is fetched, all TOE files are deleted with no marker left behind. A subsequent `/result` poll returns `"not_found"`, which is indistinguishable from a job ID that never existed. Should add an `"already_downloaded"` marker and reason (similar to how the stale sweeper leaves `.expired`).

* **Non-TDX builds are currently broken.** The build pipeline and custodes service assume TDX hardware is available (quote generator, RTMR2 recording). Builds without `--tdx` will fail at the RTMR2 recording step and the service may not start correctly. Use `--tdx` on TDX-capable hardware for now.

## Possible improvements

* Make `--debug` builds announce themselves unmistakably at runtime, not just at build time.
* Fold `add-payload.sh` into `build-base.sh` as a function, and split `build-base.sh` itself into
  functions — it is long and linear.
* Make the base-image build reproducible, which would remove the two-step build entirely.
