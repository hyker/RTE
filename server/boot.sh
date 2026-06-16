#!/bin/bash
#
MODE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --prod)
      MODE="prod"
      shift
      ;;
    --dev)
      MODE="dev"
      shift
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 --prod|--dev"
      echo "  --prod: Port 8444, SSH 2222 (production image)"
      echo "  --dev:  Port 9444, SSH 2223 (dev overlay image)"
      exit 1
      ;;
  esac
done

if [ -z "$MODE" ]; then
  echo "Error: --prod or --dev required"
  echo "Usage: $0 --prod|--dev"
  exit 1
fi

# Derive base image name from mode
case $MODE in
  prod)
    BASE_IMAGE="verity-image.img"
    ;;
  dev)
    BASE_IMAGE="verity-dev-image.img"
    ;;
esac

# Load and verify image metadata
if [ ! -f "${BASE_IMAGE}.meta" ]; then
  echo "Error: ${BASE_IMAGE}.meta not found. Run build-base.sh and setup-verity.sh [--dev] first."
  exit 1
fi
if [ ! -f "$BASE_IMAGE" ]; then
  echo "Error: $BASE_IMAGE not found."
  exit 1
fi

source "${BASE_IMAGE}.meta"

# Load CF API token and pass to VM via fw_cfg (never touches the image)
if [ ! -f secrets.sh ]; then
  echo "Error: secrets.sh not found. Create it with CF_API_TOKEN=<token>."
  exit 1
fi
source secrets.sh

CF_INI_FILE=$(mktemp)
chmod 600 "$CF_INI_FILE"
printf 'dns_cloudflare_api_token = %s\n' "$CF_API_TOKEN" > "$CF_INI_FILE"
trap "rm -f $CF_INI_FILE" EXIT

FW_CFG_ARGS=(
  -fw_cfg "name=opt/certbot/cloudflare-ini,file=${CF_INI_FILE}"
)

USE_TDX=$TDX
VM_MEMORY=$VM_MEMORY

# Configure ports and image
case $MODE in
  prod)
    HTTPS_PORT=8444
    SSH_PORT=2222
    VM_NAME="verity-prod"
    GUEST_CID=6
    DISK_IMAGE="verity-prod-overlay.img"
    DISK_OPTS=",backing.file.locking=off"
    rm -f "$DISK_IMAGE"
    qemu-img create -f qcow2 -b "$BASE_IMAGE" -F qcow2 "$DISK_IMAGE" >/dev/null
    ;;
  dev)
    HTTPS_PORT=9444
    SSH_PORT=2223
    VM_NAME="verity-dev"
    GUEST_CID=7
    DISK_IMAGE="verity-dev-overlay.img"
    DISK_OPTS=",backing.file.locking=off"
    rm -f "$DISK_IMAGE"
    qemu-img create -f qcow2 -b "$BASE_IMAGE" -F qcow2 "$DISK_IMAGE" >/dev/null
    ;;
esac

if [ "$USE_TDX" = true ]; then
  CPU_ARGS="host"
  if [ -f /etc/os-release ]; then
    VERSION_ID=$(grep VERSION_ID /etc/os-release | cut -d'=' -f2 | tr -d '"')
    if [ "$VERSION_ID" != "24.04" ]; then
      CPU_ARGS="host,-avx10"
    fi
  fi

  qemu-system-x86_64 \
    -accel kvm \
    -cpu "$CPU_ARGS" \
    -smp 4 \
    -m $VM_MEMORY \
    -name $VM_NAME,process=$VM_NAME,debug-threads=on \
    -object '{"qom-type":"tdx-guest","id":"tdx","quote-generation-socket":{"type": "vsock", "cid":"'$GUEST_CID'","port":"4050"}}' \
    -object "memory-backend-ram,id=mem0,size=${VM_MEMORY}M" \
    -machine q35,kernel_irqchip=split,confidential-guest-support=tdx,memory-backend=mem0 \
    -bios /usr/share/ovmf/OVMF.fd \
    -nographic \
    -nodefaults \
    -vga none \
    -daemonize \
    -device virtio-net-pci,netdev=nic0 \
    -netdev user,id=nic0,hostfwd=tcp::$SSH_PORT-:22,hostfwd=tcp:0.0.0.0:$HTTPS_PORT-:9000 \
    -drive file=$DISK_IMAGE,if=none,id=virtio-disk0,format=qcow2$DISK_OPTS \
    -device virtio-blk-pci,drive=virtio-disk0 \
    -device vhost-vsock-pci,guest-cid=$GUEST_CID \
    "${FW_CFG_ARGS[@]}"
else
  qemu-system-x86_64 \
    -enable-kvm \
    -cpu host \
    -smp 4 \
    -m $VM_MEMORY \
    -name $VM_NAME,process=$VM_NAME \
    -drive file=$DISK_IMAGE,format=qcow2,if=virtio$DISK_OPTS \
    -device vhost-vsock-pci,guest-cid=$GUEST_CID \
    -net nic -net user,hostfwd=tcp:0.0.0.0:$HTTPS_PORT-:9000,hostfwd=tcp::$SSH_PORT-:22 \
    -daemonize \
    -display none \
    "${FW_CFG_ARGS[@]}"
fi

echo "VM started ($MODE): https://localhost:$HTTPS_PORT (ssh port $SSH_PORT)"
echo "Stop with: pkill -f 'process=$VM_NAME'"
