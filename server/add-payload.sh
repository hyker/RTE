#!/bin/bash
# Script to add the custodes payload to a base image. Normally called from build-base.sh.
#
# Usage: ./add-payload.sh --image <path> [--debug] [--tdx]
#        ./add-payload.sh <image> <debug true|false> [tdx true|false]   (legacy positional)

set -e

usage() {
  echo "Usage: $0 --image <path> [--debug] [--tdx]"
  echo "  --image <path>  base image to modify (required)"
  echo "  --debug         build the payload for a debug image"
  echo "  --tdx           include the TDX quote generator"
  echo ""
  echo "The legacy positional form '<image> <debug> <tdx>' is still accepted."
}

BASE_IMAGE=""
DEBUG_MODE="false"
USE_TDX="false"

if [[ "$1" == --* ]]; then
  while [[ $# -gt 0 ]]; do
    case $1 in
      --image)  BASE_IMAGE="$2"; shift 2 ;;
      --debug)  DEBUG_MODE=true; shift ;;
      --tdx)    USE_TDX=true;    shift ;;
      --help|-h) usage; exit 0 ;;
      *)        echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
  done
else
  BASE_IMAGE="$1"
  DEBUG_MODE="${2:-false}"
  USE_TDX="${3:-false}"
fi

if [ -z "$BASE_IMAGE" ]; then
  echo "Error: no base image given." >&2
  usage >&2
  exit 1
fi

# Build custodes binary
cd payload/custodes
make clean
make build
cd ../..

# Build aeskeyfind from the pinned submodule. This used to fall back to cloning
# github.com/makomk/aeskeyfind at an unpinned HEAD -- a different upstream from the
# one .gitmodules declares -- which would have put unreviewed code into the attested
# image. The submodule is the only accepted source; if it is missing, say so.
if [ ! -f "payload/custodes/tools/aeskeyfind/aeskeyfind" ]; then
  if [ ! -f "payload/custodes/tools/aeskeyfind/aeskeyfind.c" ]; then
    echo "Error: payload/custodes/tools/aeskeyfind is empty." >&2
    echo "  Run: git submodule update --init --recursive" >&2
    exit 1
  fi
  echo "Building aeskeyfind..."
  cd payload/custodes/tools/aeskeyfind
  make clean
  make
  cd ../../../..
fi

# Build checksec binary
cd payload/custodes/tools/checksec
go build -o checksec .
cd ../../../..

# Download and extract dependency-check
# The dependency-check release is normally vendored in the repo; this downloads it
# only if that tree is absent. It lands in the attested image either way, so the
# archive is pinned by digest. Upstream publishes no checksum file alongside the
# release, so this digest was computed from the archive and verified to match the
# vendored tree byte for byte.
DC_VERSION="12.1.6"
DC_SHA256="1d8a60e379099e33009d2d105daa9f52b27f4ac5dc1859a279c76fbc2096c2ed"
if [ ! -d "payload/custodes/tools/dependency-check" ]; then
  echo "Downloading dependency-check ${DC_VERSION}..."
  cd payload/custodes/tools
  curl -Ls "https://github.com/dependency-check/DependencyCheck/releases/download/v${DC_VERSION}/dependency-check-${DC_VERSION}-release.zip" -o dependency-check.zip
  ACTUAL_SHA=$(sha256sum dependency-check.zip | awk '{print $1}')
  if [ "$ACTUAL_SHA" != "$DC_SHA256" ]; then
    echo "Error: dependency-check archive checksum mismatch." >&2
    echo "  expected: $DC_SHA256" >&2
    echo "  actual:   $ACTUAL_SHA" >&2
    rm -f dependency-check.zip
    exit 1
  fi
  unzip -q dependency-check.zip
  rm dependency-check.zip
  cd ../../..
fi

# Install custodes binary and support files
sudo LIBGUESTFS_BACKEND=direct virt-customize --format=raw -a "$BASE_IMAGE" \
  --copy-in payload/custodes/custodes:/usr/local/bin \
  --run-command "chmod +x /usr/local/bin/custodes"

# Install cppcheck and binwalk
sudo LIBGUESTFS_BACKEND=direct virt-customize --format=raw -a "$BASE_IMAGE" \
  --install cppcheck,binwalk

# Install checksec
sudo LIBGUESTFS_BACKEND=direct virt-customize --format=raw -a "$BASE_IMAGE" \
  --run-command "mkdir -p /opt/custodes/tools" \
  --copy-in payload/custodes/tools/checksec:/opt/custodes/tools \
  --run-command "chmod +x /opt/custodes/tools/checksec/checksec"

# Install aeskeyfind
sudo LIBGUESTFS_BACKEND=direct virt-customize --format=raw -a "$BASE_IMAGE" \
  --copy-in payload/custodes/tools/aeskeyfind:/opt/custodes/tools \
  --run-command "chmod +x /opt/custodes/tools/aeskeyfind/aeskeyfind"

# Install Java and dependency-check
sudo LIBGUESTFS_BACKEND=direct virt-customize --format=raw -a "$BASE_IMAGE" \
  --install default-jre-headless \
  --copy-in payload/custodes/tools/dependency-check:/opt/custodes/tools \
  --run-command "chmod +x /opt/custodes/tools/dependency-check/bin/dependency-check.sh"

# Build and install TDX quote generator (only for TDX builds)
if [ "$USE_TDX" = "true" ]; then
  sudo LIBGUESTFS_BACKEND=direct virt-customize --format=raw -a "$BASE_IMAGE" \
    --run-command "mkdir -p /opt/tdx-quote-service" \
    --copy-in payload/tdx-quote-service/quote-generator/quote-generator.c:/tmp \
    --run-command "gcc -Wall -O2 -o /opt/tdx-quote-service/quote-generator /tmp/quote-generator.c -ltdx_attest" \
    --run-command "rm /tmp/quote-generator.c"
fi

# Create dedicated non-root user for the custodes service. The service binds
# the unprivileged port 9000 and writes only to tmpfs paths it owns, so it
# doesn't need root. TLS files and (for TDX builds) /dev/tdx_guest are made
# readable via the custodes group below.
sudo LIBGUESTFS_BACKEND=direct virt-customize --format=raw -a "$BASE_IMAGE" \
  --run-command "useradd --system --no-create-home --shell /usr/sbin/nologin custodes"

# For TDX builds, /dev/tdx_guest defaults to root-only; grant the custodes
# group read access so the quote-generator subprocess (running as custodes)
# can still produce a quote.
if [ "$USE_TDX" = "true" ]; then
  sudo LIBGUESTFS_BACKEND=direct virt-customize --format=raw -a "$BASE_IMAGE" \
    --copy-in payload/udev/70-tdx-guest.rules:/etc/udev/rules.d
fi

# Setup custodes systemd service
sudo LIBGUESTFS_BACKEND=direct virt-customize --format=raw -a "$BASE_IMAGE" \
  --copy-in payload/systemd/custodes.service:/etc/systemd/system \
  --run-command "systemctl enable custodes.service"

# Install TLS provisioning script and service
sudo LIBGUESTFS_BACKEND=direct virt-customize --format=raw -a "$BASE_IMAGE" \
  --copy-in payload/tls-provision.sh:/usr/local/bin \
  --run-command "chmod +x /usr/local/bin/tls-provision.sh" \
  --copy-in payload/systemd/tls-provision.service:/etc/systemd/system \
  --run-command "systemctl enable tls-provision.service"

# Install TLS renewal script, service and timer
sudo LIBGUESTFS_BACKEND=direct virt-customize --format=raw -a "$BASE_IMAGE" \
  --copy-in payload/tls-renew.sh:/usr/local/bin \
  --run-command "chmod +x /usr/local/bin/tls-renew.sh" \
  --copy-in payload/systemd/tls-renew.service:/etc/systemd/system \
  --copy-in payload/systemd/tls-renew.timer:/etc/systemd/system \
  --run-command "systemctl enable tls-renew.timer"
