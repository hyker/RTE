#!/bin/bash
set -e

# Request sudo password upfront and keep session alive
sudo -v
# Keep sudo session alive in background
while true; do sudo -n true; sleep 50; kill -0 "$$" || exit; done 2>/dev/null &

# Parse command line arguments
USE_TDX=false
DEBUG_MODE=false
MODE="dev"
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
      echo "Usage: $0 [--prod|--dev] [--tdx] [--debug]"
      echo "  --prod:  use production LE certs (default is staging)"
      echo "  --dev:   use LE staging certs (default)"
      echo "  --tdx:   build with TDX support"
      echo "  --debug: enable debug mode (keeps SSH and extra services enabled)"
      exit 1
      ;;
  esac
done

# Load certbot configuration (domain, email — baked into image, no secrets)
if [ ! -f build-config.sh ]; then
  echo "Error: build-config.sh not found. Create it with LE_DOMAIN, LE_EMAIL."
  exit 1
fi
source build-config.sh

# Exported so add-payload.sh -> the custodes Makefile picks it up and bakes the
# anti-freeloading gate origin into the binary (empty disables the gate).
export ALLOWED_REFERRER_ORIGIN

# LE staging by default (safe); only --prod uses production certs
if [ "$MODE" = "prod" ]; then
  LE_STAGING="false"
else
  LE_STAGING="true"
fi

# Tmpfs size configuration (overridable via environment variables)
# Minimum requirements: /tmp=10G (payload storage), /var/log=256M, /var/tmp=2G (dependency-check database)
# /var/lib and /var/cache are NOT tmpfs: a bare tmpfs there hides /var/lib/dpkg and
# leaves apt inert. They come from the root overlay instead (see overlayroot below).
TMPFS_SIZE_TMP="${TMPFS_SIZE_TMP:-10G}"
TMPFS_SIZE_VAR_LOG="${TMPFS_SIZE_VAR_LOG:-256M}"
TMPFS_SIZE_VAR_TMP="${TMPFS_SIZE_VAR_TMP:-2G}"
TMPFS_SIZE_JOURNAL="${TMPFS_SIZE_JOURNAL:-64M}"
# Root-overlay upper layer. NOTE: overlayroot parses only swap/recurse/debug/dir/driver
# and drops any size= (it mounts the tmpfs bare), so this is a RAM *budget* used to size
# the VM, not an enforced limit. The upper layer can grow to the kernel default of 50% RAM.
TMPFS_SIZE_OVERLAY="${TMPFS_SIZE_OVERLAY:-2G}"

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

TOTAL_TMPFS=$(($(calculate_mb $TMPFS_SIZE_TMP) + $(calculate_mb $TMPFS_SIZE_VAR_LOG) + $(calculate_mb $TMPFS_SIZE_VAR_TMP) + $(calculate_mb $TMPFS_SIZE_JOURNAL) + $(calculate_mb $TMPFS_SIZE_OVERLAY)))
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

# Bring the base fully up to date before anything is layered on top of it.
# The downloaded Ubuntu cloud image -- and the TDX qcow2 built from it -- is a
# snapshot that drifts further behind with every week since its release, and it is
# cached locally across builds, so without this a fresh build can still ship
# months-old packages. Doing it first also means the --install passes below and
# add-payload.sh resolve against current package lists.
#
# This is also the only path for kernel and microcode fixes: those take effect at
# boot, and a reboot returns the VM to this image, so applying them at runtime
# would achieve nothing.
#
# dist-upgrade rather than upgrade: a kernel ABI bump arrives as a new package name
# (linux-image-6.8.0-NNN-generic), which plain upgrade will not pull in.
#
# Whenever this actually upgrades something the rootfs changes, and with it the
# verity root hash and RTMR2 -- so re-record measurements and rebuild the client.
sudo LIBGUESTFS_BACKEND=direct virt-customize --format=raw -a base-working.raw \
  --run-command "apt-get update" \
  --run-command "DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade --yes" \
  --run-command "apt-get clean"

# expand image to accomodate a verity hash tree on a separate partition
qemu-img resize -f raw base-working.raw +128M # 128M for verity hash (larger images need more)
sgdisk -e base-working.raw
sgdisk -p base-working.raw

# Create verity hash partition (partition 5) - uses remaining space (128M)
sgdisk -n 5:0:0 -t 5:8300 -c 5:"verity-hash" base-working.raw

# Placeholder values for dm-verity (will be replaced in grub.cfg by setup-verity.sh)
PLACEHOLDER_HASH="0000000000000000000000000000000000000000000000000000000000000000"
SALT="eeafe117234ef8295fbed9aa846b45efabe53f2af502342cf50ca3ec709edf7d"

# NOTE: no 'ro' here. overlayroot keys off a literal ' ro ' anywhere in the cmdline
# (init-bottom/overlayroot:703) and remounts the *overlay* read-only when it finds one,
# leaving apt unable to write. Dropping it here is necessary but NOT sufficient:
# grub-mkconfig hardcodes its own ' ro ' into every linux line (/etc/grub.d/10_linux:261
# and :286), so that copy has to be stripped from grub.cfg after update-grub -- see the
# sed near the end of this script. The verity root still mounts read-only either way,
# because initramfs-tools defaults to readonly=y (/usr/share/initramfs-tools/init:73)
# and nothing puts 'rw' on the cmdline.
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
  --run-command "sed -i 's|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"dm-mod.create=\\\\\"vroot,,,ro,0 DMSIZE_PLACEHOLDER verity 1 /dev/vda1 /dev/vda5 4096 4096 DATABLOCKS_PLACEHOLDER 1 sha256 ${PLACEHOLDER_HASH} ${SALT}\\\\\" root=/dev/dm-0 rootwait\"|' /etc/default/grub" \
  --run-command "echo dm-verity >> /etc/initramfs-tools/modules" \
  --run-command "systemctl mask snapd.service snapd.socket" \
  --run-command "systemctl mask sysstat.service" \
  --run-command "systemctl mask systemd-remount-fs.service" \
  --run-command "cat >> /etc/fstab <<EOF
# tmpfs mounts for writable directories (read-only root via dm-verity)
tmpfs  /tmp        tmpfs  size=$TMPFS_SIZE_TMP,noswap,mode=1777 0 0
tmpfs  /var/log    tmpfs  size=$TMPFS_SIZE_VAR_LOG,noswap,mode=0755  0 0
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

# Root overlay: make the dm-verity root writable at runtime so apt/dpkg work.
# overlayroot's init-bottom hook moves the (read-only) verity root aside as the
# overlay lowerdir and mounts a tmpfs upper on top -- the verity device itself is
# never remounted rw, so integrity checking of the lower layer is unaffected.
# The upper layer is RAM and is discarded on reboot, so a reboot still returns the
# VM to the pristine, attested base image.
# Installing this regenerates the initramfs, which changes RTMR2 -- re-record after.
sudo LIBGUESTFS_BACKEND=direct virt-customize --format=raw -a base-working.raw \
  --install overlayroot \
  --run-command "printf 'overlayroot_cfgdisk=\"disabled\"\noverlayroot=\"tmpfs\"\n' > /etc/overlayroot.conf"

# Unattended-upgrades policy. Written as 99zz-* deliberately: apt.conf.d is read in
# lexical order and later files win, so this must sort AFTER the kobuk PPA drop-ins
# (99unattended-upgrades-kobuk-*) for the Allow-downgrade override to take effect.
# Also lower the kobuk pins from 4000 to 1000: apt treats any priority above 1000 as
# licence to downgrade, so the pin alone would permit exactly what we are disabling.
# NB: setup-tdx-guest.sh recreates both of those files, so this must run after it --
# it does, because that script only runs when the TDX base qcow2 is (re)built.
sudo LIBGUESTFS_BACKEND=direct virt-customize --format=raw -a base-working.raw \
  --run-command "sed -i 's/^Pin-Priority: 4000/Pin-Priority: 1000/' /etc/apt/preferences.d/*kobuk* 2>/dev/null || true" \
  --run-command "cat > /etc/apt/apt.conf.d/99zz-rte-unattended-upgrades <<'APTEOF'
// Kernel and CPU microcode only take effect at boot, and a reboot returns this VM to
// the pristine attested base image -- so they belong in the image build, not the
// runtime path. Unpacking them at runtime only consumes overlay RAM to no effect.
//
// No leading ^: unattended-upgrades matches these with re.match (already anchored at
// the start) and separately turns each one into an apt pin as '/^<regex>/', so a ^ here
// yields '/^^linux-/', which matches nothing and silently drops the pin. Ubuntu's own
// generated entries use the same unanchored-at-start form.
Unattended-Upgrade::Package-Blacklist {
  \"linux-\";
  \"linux\$\";
  \"intel-microcode\$\";
};

// Never downgrade. See the pin note above.
Unattended-Upgrade::Allow-downgrade \"false\";

// The overlay upper layer is tmpfs, i.e. RAM, and grows monotonically until reboot.
// Drop orphaned packages and the downloaded archives to keep growth to the installed
// delta rather than the whole download history.
Unattended-Upgrade::Remove-Unused-Dependencies \"true\";
Unattended-Upgrade::Post-Invoke {\"/usr/bin/apt-get clean\";};
APTEOF"

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

# Canonical's TDX setup pins a specific kernel: setup-tdx-common:80-90 writes
# /etc/default/grub.d/99-tdx-kernel.cfg with GRUB_DEFAULT=saved and points grubenv's
# saved_entry at whatever generic kernel was newest when the TDX base qcow2 was built.
# That base is cached for months, so the pin outlives it and the build-time dist-upgrade
# goes inert for the kernel: the new one installs and becomes the top menu entry, while
# GRUB goes on booting the old saved one.
#
# Its intent -- boot the newest generic kernel -- is ours too, so take entry 0 instead,
# which stays correct after an upgrade. The file has to sort AFTER 99-tdx-kernel.cfg
# (grub.d is sourced in lexical order, last assignment wins), hence 99-zz-.
# Determinism matters here beyond the upgrade: under GRUB_DEFAULT=saved, which kernel
# boots is a function of leftover grubenv state rather than of the image -- and the
# kernel is measured into RTMR2.
sudo LIBGUESTFS_BACKEND=direct virt-customize --format=raw -a base-working.raw \
  --run-command "mkdir -p /etc/default/grub.d" \
  --run-command "printf 'GRUB_DEFAULT=0\nGRUB_SAVEDEFAULT=false\n' > /etc/default/grub.d/99-zz-rte-boot.cfg" \
  --run-command "update-grub" \
  --run-command "update-initramfs -u -k all" \
  --run-command "grub-editenv /boot/grub/grubenv unset saved_entry" \
  --run-command "if ! grep -q 'set default=\"0\"' /boot/grub/grub.cfg; then echo 'ERROR: grub default is not entry 0'; exit 1; fi" \
  --run-command "sed -i '/dm-mod.create/ s/ ro / /' /boot/grub/grub.cfg" \
  --run-command "if grep dm-mod.create /boot/grub/grub.cfg | grep -q ' ro '; then echo 'ERROR: ro still on the verity cmdline'; exit 1; fi"

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
