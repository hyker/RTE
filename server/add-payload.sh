#!/bin/bash
# Script to add custodes payload to base image
# Called from build-base.sh
# Parameters: $1 = base image file path, $2 = debug mode (true/false), $3 = use TDX (true/false)

set -e

BASE_IMAGE="$1"
DEBUG_MODE="$2"
USE_TDX="${3:-false}"

# Build custodes binary
cd payload/custodes
make clean
make build
cd ../..

# Build checksec binary
cd payload/custodes/tools/checksec
go build -o checksec .
cd ../../../..

# Download and extract dependency-check
if [ ! -d "payload/custodes/tools/dependency-check" ]; then
  echo "Downloading dependency-check..."
  cd payload/custodes/tools
  curl -Ls "https://github.com/dependency-check/DependencyCheck/releases/download/v12.1.6/dependency-check-12.1.6-release.zip" -o dependency-check.zip
  unzip -q dependency-check.zip
  rm dependency-check.zip
  cd ../../..
fi

# Install custodes binary and support files
sudo LIBGUESTFS_BACKEND=direct virt-customize --format=raw -a "$BASE_IMAGE" \
  --copy-in payload/custodes/custodes:/usr/local/bin \
  --run-command "chmod +x /usr/local/bin/custodes"

# Install cppcheck
sudo LIBGUESTFS_BACKEND=direct virt-customize --format=raw -a "$BASE_IMAGE" \
  --install cppcheck

# Install checksec
sudo LIBGUESTFS_BACKEND=direct virt-customize --format=raw -a "$BASE_IMAGE" \
  --run-command "mkdir -p /opt/custodes/tools" \
  --copy-in payload/custodes/tools/checksec:/opt/custodes/tools \
  --run-command "chmod +x /opt/custodes/tools/checksec/checksec"

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
