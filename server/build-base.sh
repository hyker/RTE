#!/bin/bash
set -e

# Request sudo password upfront and keep session alive
sudo -v
# Keep sudo session alive in background
while true; do sudo -n true; sleep 50; kill -0 "$$" || exit; done 2>/dev/null &

# Parse command line arguments
USE_TDX=false
DEBUG_MODE=false
while [[ $# -gt 0 ]]; do
  case $1 in
    --tdx)
      USE_TDX=true
      shift
      ;;
    --debug)
      DEBUG_MODE=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--tdx] [--debug]"
      echo "  --tdx:   build with TDX support"
      echo "  --debug: enable debug mode (keeps SSH and extra services enabled)"
      exit 1
      ;;
  esac
done

# Load certbot configuration (domain, email, staging flag — baked into image, no secrets)
if [ ! -f build-config.sh ]; then
  echo "Error: build-config.sh not found. Create it with LE_DOMAIN, LE_EMAIL, LE_STAGING."
  exit 1
fi
source build-config.sh

# Tmpfs size configuration (overridable via environment variables)
# Minimum requirements: /tmp=10G (payload storage), /var/log=256M, /var/lib=128M, /var/cache=64M, /var/tmp=2G (dependency-check database)
TMPFS_SIZE_TMP="${TMPFS_SIZE_TMP:-10G}"
TMPFS_SIZE_VAR_LOG="${TMPFS_SIZE_VAR_LOG:-256M}"
TMPFS_SIZE_VAR_LIB="${TMPFS_SIZE_VAR_LIB:-128M}"
TMPFS_SIZE_VAR_CACHE="${TMPFS_SIZE_VAR_CACHE:-64M}"
TMPFS_SIZE_VAR_TMP="${TMPFS_SIZE_VAR_TMP:-2G}"
TMPFS_SIZE_JOURNAL="${TMPFS_SIZE_JOURNAL:-64M}"

# Calculate required VM RAM (tmpfs + 2GB overhead)
calculate_mb() {
  local size=$1
  local value=${size%[MG]}
  local unit=${size: -1}
  if [ "$unit" = "G" ]; then
    echo $((value * 1024))
  else
    echo $value
  fi
}

TOTAL_TMPFS=$(($(calculate_mb $TMPFS_SIZE_TMP) + $(calculate_mb $TMPFS_SIZE_VAR_LOG) + $(calculate_mb $TMPFS_SIZE_VAR_LIB) + $(calculate_mb $TMPFS_SIZE_VAR_CACHE) + $(calculate_mb $TMPFS_SIZE_VAR_TMP) + $(calculate_mb $TMPFS_SIZE_JOURNAL)))
REQUIRED_VM_RAM=$((TOTAL_TMPFS + 2048))

# Prompt for root password in debug mode; randomise it in production (SSH is masked)
if [ "$DEBUG_MODE" = true ]; then
  while true; do
    read -s -p "Enter root password for debug SSH access: " ROOT_PASSWORD
    echo
    read -s -p "Confirm password: " ROOT_PASSWORD_CONFIRM
    echo
    if [ "$ROOT_PASSWORD" = "$ROOT_PASSWORD_CONFIRM" ]; then
      break
    fi
    echo "Passwords do not match, try again."
  done
else
  ROOT_PASSWORD=$(openssl rand -base64 32)
fi

if [ "$USE_TDX" = true ]; then

  # rely on canonical scripts for building a TDX enabeled base image
  if [ ! -f tdx-guest-ubuntu-24.04-generic.qcow2 ]; then

    # Use our custom config with attestation enabled
    cp setup-tdx-config-custom tdx/setup-tdx-config

    cd tdx/guest-tools/image
    sudo TDX_SETUP_ATTESTATION=1 ./create-td-image.sh -v 24.04
    cp tdx-guest-ubuntu-24.04-generic.qcow2 ../../..
    cd ../../..
  fi

  # convert it to format we can work with
  qemu-img convert -f qcow2 -O raw tdx-guest-ubuntu-24.04-generic.qcow2 base-working.raw
else

  # download plain ubuntu image as base (qcow2 format)
  if [ ! -f ubuntu-24.04-server-cloudimg-amd64.img ]; then
    wget https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img
  fi

  # convert it to format we can work with
  qemu-img convert -f qcow2 -O raw ubuntu-24.04-server-cloudimg-amd64.img base-working.raw
fi

# expand image to accomodate a verity hash tree on a separate partition
qemu-img resize -f raw base-working.raw +128M # 128M for verity hash (larger images need more)
sgdisk -e base-working.raw
sgdisk -p base-working.raw

# Create verity hash partition (partition 5) - uses remaining space (128M)
sgdisk -n 5:0:0 -t 5:8300 -c 5:"verity-hash" base-working.raw

# Placeholder values for dm-verity (will be replaced in grub.cfg by setup-verity.sh)
PLACEHOLDER_HASH="0000000000000000000000000000000000000000000000000000000000000000"
SALT="eeafe117234ef8295fbed9aa846b45efabe53f2af502342cf50ca3ec709edf7d"

# add login and ssh for debug, configure network, and prepare for dm-verity
sudo LIBGUESTFS_BACKEND=direct virt-customize --format=raw -a base-working.raw --root-password "password:$ROOT_PASSWORD" \
  --run-command "sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config" \
  --run-command "sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config" \
  --run-command "rm -f /etc/ssh/sshd_config.d/60-cloudimg-settings.conf" \
  --run-command "ssh-keygen -A" \
  --run-command "systemctl enable ssh" \
  --run-command "mkdir -p /etc/netplan" \
  --run-command "cat > /etc/netplan/01-netcfg.yaml <<EOF
network:
  version: 2
  ethernets:
    ens3:
      dhcp4: true
EOF" \
  --run-command "sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"\"/' /etc/default/grub" \
  --run-command "sed -i 's|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"dm-mod.create=\\\\\"vroot,,,ro,0 DMSIZE_PLACEHOLDER verity 1 /dev/vda1 /dev/vda5 4096 4096 DATABLOCKS_PLACEHOLDER 1 sha256 ${PLACEHOLDER_HASH} ${SALT}\\\\\" root=/dev/dm-0 rootwait ro\"|' /etc/default/grub" \
  --run-command "echo dm-verity >> /etc/initramfs-tools/modules" \
  --run-command "systemctl mask snapd.service snapd.socket" \
  --run-command "systemctl mask sysstat.service" \
  --run-command "systemctl mask systemd-remount-fs.service" \
  --run-command "cat >> /etc/fstab <<EOF
# tmpfs mounts for writable directories (read-only root via dm-verity)
tmpfs  /tmp        tmpfs  size=$TMPFS_SIZE_TMP,noswap,mode=1777 0 0
tmpfs  /var/log    tmpfs  size=$TMPFS_SIZE_VAR_LOG,noswap,mode=0755  0 0
tmpfs  /var/lib    tmpfs  size=$TMPFS_SIZE_VAR_LIB,noswap,mode=0755  0 0
tmpfs  /var/cache  tmpfs  size=$TMPFS_SIZE_VAR_CACHE,noswap,mode=0755   0 0
tmpfs  /var/tmp    tmpfs  size=$TMPFS_SIZE_VAR_TMP,noswap,mode=1777   0 0
EOF" \
  --run-command "mkdir -p /etc/systemd/journald.conf.d" \
  --run-command "cat > /etc/systemd/journald.conf.d/ram-only.conf <<EOF
[Journal]
Storage=volatile
RuntimeMaxUse=$TMPFS_SIZE_JOURNAL
EOF"

# Install certbot and bake in non-secret certbot configuration
sudo LIBGUESTFS_BACKEND=direct virt-customize --format=raw -a base-working.raw \
  --install certbot,python3-certbot-dns-cloudflare \
  --run-command "mkdir -p /opt/certbot" \
  --run-command "printf 'LE_DOMAIN=%s\nLE_EMAIL=%s\nLE_STAGING=%s\n' '${LE_DOMAIN}' '${LE_EMAIL}' '${LE_STAGING}' > /opt/certbot/certbot.env"

# Payload installation (see add-payload.sh)
./add-payload.sh base-working.raw "$DEBUG_MODE" "$USE_TDX"

# Conditionally mask services based on debug mode
if [ "$DEBUG_MODE" = false ]; then
  sudo LIBGUESTFS_BACKEND=direct virt-customize --format=raw -a base-working.raw \
    --run-command "systemctl mask ssh.service" \
    --run-command "systemctl mask systemd-logind.service" \
    --run-command "systemctl mask multipathd.service" \
    --run-command "systemctl mask ModemManager.service" \
    --run-command "systemctl mask rsyslog.service" \
    --run-command "passwd -l root" \
    --run-command "systemctl mask getty@.service serial-getty@.service"
fi

sudo LIBGUESTFS_BACKEND=direct virt-customize --format=raw -a base-working.raw \
  --run-command "update-grub" \
  --run-command "update-initramfs -u -k all"

# Save as cached base image
mv base-working.raw base-image.raw

# Write build metadata for setup-verity.sh and boot.sh to consume
cat > build.meta <<EOF
TDX=$USE_TDX
DEBUG=$DEBUG_MODE
VM_MEMORY=$REQUIRED_VM_RAM
EOF

echo "Base image written to base-image.raw"
echo "Required VM RAM: ${REQUIRED_VM_RAM}M"
