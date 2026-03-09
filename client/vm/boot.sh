#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

HTTPS_PORT="${HTTPS_PORT:-8445}"
VM_NAME="${VM_NAME:-quote-verifier-web}"
DISK="${DISK:-vm-disk.qcow2}"
SEED="${SEED:-seed.iso}"
WEBROOT="${WEBROOT:-webroot.iso}"
LOG="${LOG:-vm.log}"
MONITOR_PORT="${MONITOR_PORT:-4444}"

# Check if VM is already running
if pgrep -f "process=$VM_NAME" >/dev/null 2>&1; then
  echo "VM is already running."
  echo "  https://localhost:$HTTPS_PORT"
  echo "Stop with: pkill -f 'process=$VM_NAME'"
  exit 1
fi

# Verify build artifacts exist
for f in "$DISK" "$SEED" "$WEBROOT"; do
  if [ ! -f "$f" ]; then
    echo "Missing $f — run ./build.sh first"
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

echo "VM started."
echo "  https://localhost:$HTTPS_PORT"
echo ""
echo "Stop with: pkill -f 'process=$VM_NAME'"
