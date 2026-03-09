#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

exec env \
  HTTPS_PORT=8446 \
  VM_NAME=quote-verifier-staging \
  DISK=vm-disk-staging.qcow2 \
  SEED=seed-staging.iso \
  WEBROOT=webroot-staging.iso \
  LOG=vm-staging.log \
  MONITOR_PORT=4445 \
  ./boot.sh "$@"
