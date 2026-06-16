#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

MODE=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --prod) MODE="prod"; shift ;;
    --dev)  MODE="dev";  shift ;;
    *)
      echo "Usage: $0 --prod|--dev"
      exit 1
      ;;
  esac
done

if [ -z "$MODE" ]; then
  echo "Usage: $0 --prod|--dev"
  exit 1
fi

case $MODE in
  prod)
    HTTPS_PORT=8445
    VM_NAME="quote-verifier-prod"
    DISK="vm-disk-prod.qcow2"
    SEED="seed-prod.iso"
    WEBROOT="webroot-prod.iso"
    MONITOR_PORT=4444
    LOG="vm-prod.log"
    ;;
  dev)
    HTTPS_PORT=9445
    VM_NAME="quote-verifier-dev"
    DISK="vm-disk-dev.qcow2"
    SEED="seed-dev.iso"
    WEBROOT="webroot-dev.iso"
    MONITOR_PORT=4445
    LOG="vm-dev.log"
    ;;
esac

# Check if VM is already running
if pgrep -f "process=$VM_NAME" >/dev/null 2>&1; then
  echo "VM already running ($MODE)."
  echo "  https://localhost:$HTTPS_PORT"
  echo "Stop with: pkill -f 'process=$VM_NAME'"
  exit 1
fi

# Verify build artifacts exist
for f in "$DISK" "$SEED" "$WEBROOT"; do
  if [ ! -f "$f" ]; then
    echo "Missing $f — run ./build.sh --$MODE first"
    exit 1
  fi
done

qemu-system-x86_64 \
  -enable-kvm \
  -cpu host \
  -smp 2 \
  -m 2048 \
  -name "$VM_NAME",process="$VM_NAME" \
  -drive file="$DISK",format=qcow2,if=virtio \
  -drive file="$SEED",format=raw,media=cdrom,index=0 \
  -drive file="$WEBROOT",format=raw,media=cdrom,index=1 \
  -net nic \
  -net user,hostfwd=tcp:0.0.0.0:${HTTPS_PORT}-:443 \
  -daemonize \
  -display none \
  -serial file:"$LOG" \
  -monitor tcp:127.0.0.1:${MONITOR_PORT},server,nowait

echo "VM started ($MODE)."
echo "  https://rteverif.xyz:$HTTPS_PORT"
echo ""
echo "Stop with: pkill -f 'process=$VM_NAME'"
