#!/bin/bash
set -e

# Parse arguments
MODE="dev"
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
      echo "Usage: $0 [--prod|--dev]"
      echo "  --prod: write verity-image.img"
      echo "  --dev:  write verity-dev-image.img (default)"
      exit 1
      ;;
  esac
done

if [ "$MODE" = "prod" ]; then
  OUTPUT_IMAGE="verity-image.img"
else
  OUTPUT_IMAGE="verity-dev-image.img"
fi

# get sudo capabilities for later
sudo -v

# keepalive sudo
while true; do
  sudo -n true
  sleep 60
  kill -0 "$$" || exit
done 2>/dev/null &

# Work on a copy of the cached base (which already has placeholder verity config)
cp base-image.raw verity-working.raw

# Fixed salt for deterministic behaviour
SALT=eeafe117234ef8295fbed9aa846b45efabe53f2af502342cf50ca3ec709edf7d
PLACEHOLDER_HASH="0000000000000000000000000000000000000000000000000000000000000000"

# Dynamically get partition offsets and sizes from the image
# Get partition 1 info (root filesystem)
PART1_INFO=$(sgdisk -i 1 verity-working.raw | grep "Partition GUID code\|First sector\|Last sector")
PART1_START=$(echo "$PART1_INFO" | grep "First sector:" | awk '{print $3}')
PART1_END=$(echo "$PART1_INFO" | grep "Last sector:" | awk '{print $3}')
PART1_SIZE=$((PART1_END - PART1_START + 1))

# Get partition 5 info (verity hash tree)
PART5_INFO=$(sgdisk -i 5 verity-working.raw | grep "Partition GUID code\|First sector\|Last sector")
PART5_START=$(echo "$PART5_INFO" | grep "First sector:" | awk '{print $3}')
PART5_END=$(echo "$PART5_INFO" | grep "Last sector:" | awk '{print $3}')
PART5_SIZE=$((PART5_END - PART5_START + 1))

# calculate verity hash (partition 1 is already finalized in base-cached.raw)
DEVICE_TO_HASH=$(sudo losetup -f --show -o $((PART1_START * 512)) --sizelimit $((PART1_SIZE * 512)) verity-working.raw)
HASH_TREE_RESULT=$(sudo losetup -f --show -o $((PART5_START * 512)) --sizelimit $((PART5_SIZE * 512)) verity-working.raw)

sudo veritysetup format --salt=$SALT $DEVICE_TO_HASH $HASH_TREE_RESULT >veritydata.txt

# Extract hash and data blocks
ROOT_HASH=$(grep "^Root hash:" veritydata.txt | awk '{print $3}')
DATA_BLOCKS=$(grep "^Data blocks:" veritydata.txt | awk '{print $3}')
DM_SIZE=$((DATA_BLOCKS * 8))

#verify (fail on issues)
sudo veritysetup verify $DEVICE_TO_HASH $HASH_TREE_RESULT $ROOT_HASH

# cleanup verity loop devices
sudo losetup -d $DEVICE_TO_HASH
sudo losetup -d $HASH_TREE_RESULT

# Update grub.cfg with real hash (grub.cfg is on partition 16, not protected)
LOOP_DEV=$(sudo losetup -f --show -P verity-working.raw)
sudo mkdir -p /mnt/boot
sudo mount ${LOOP_DEV}p16 /mnt/boot
sudo sed -i "s/$PLACEHOLDER_HASH/$ROOT_HASH/g" /mnt/boot/grub/grub.cfg
sudo sed -i "s/DMSIZE_PLACEHOLDER/$DM_SIZE/g" /mnt/boot/grub/grub.cfg
sudo sed -i "s/DATABLOCKS_PLACEHOLDER/$DATA_BLOCKS/g" /mnt/boot/grub/grub.cfg

# cleanup
sudo umount /mnt/boot
sudo rmdir /mnt/boot
sudo losetup -d $LOOP_DEV

# convert to bootable qcow2 image
qemu-img convert -f raw -O qcow2 verity-working.raw "$OUTPUT_IMAGE"
rm verity-working.raw

# Read build metadata written by build-base.sh
if [ ! -f build.meta ]; then
  echo "Error: build.meta not found. Run build-base.sh first."
  exit 1
fi
source build.meta

# Write final metadata
cat > "${OUTPUT_IMAGE}.meta" <<EOF
TDX=$TDX
DEBUG=$DEBUG
VM_MEMORY=$VM_MEMORY
RTMR2=
EOF

echo "Verity setup complete. Root hash written to veritydata.txt. Image written to $OUTPUT_IMAGE"
echo "Image metadata written to ${OUTPUT_IMAGE}.meta"
