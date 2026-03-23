#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
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

# --- Let's Encrypt via Cloudflare DNS-01 ---
DOMAIN="rteverif.xyz"
LE_EMAIL="joakim.brorsson@hyker.se"

case $MODE in
  prod)
    LETSENCRYPT_STAGING="false"
    DISK="vm-disk-prod.qcow2"
    SEED="seed-prod.iso"
    WEBROOT="webroot-prod.iso"
    SERVER_META="$SCRIPT_DIR/../../server/verity-image.img.meta"
    SERVICE_URL="https://custodesrte.xyz:8444"
    ;;
  dev)
    LETSENCRYPT_STAGING="true"
    DISK="vm-disk-dev.qcow2"
    SEED="seed-dev.iso"
    WEBROOT="webroot-dev.iso"
    SERVER_META="$SCRIPT_DIR/../../server/verity-dev-image.img.meta"
    SERVICE_URL="https://custodesrte.xyz:9444"
    ;;
esac

# CF_API_TOKEN is loaded from the untracked file vm/secrets.sh (not committed to git)
# Create it with: echo 'CF_API_TOKEN="your-token-here"' > vm/secrets.sh
if [ ! -f "$SCRIPT_DIR/secrets.sh" ]; then
  echo "Error: vm/secrets.sh not found. Create it with your Cloudflare API token."
  exit 1
fi
# shellcheck source=secrets.sh
source "$SCRIPT_DIR/secrets.sh"

CLOUD_IMAGE="ubuntu-cloud.img"
CLOUD_IMAGE_URL="https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"

# Build JS bundle from project root
echo "Building JS bundle..."
(cd "$PROJECT_DIR" && npm install && npm run build)

# Inject service URL
sed -i "s|__SERVICE_URL__|$SERVICE_URL|" "$PROJECT_DIR/bundle.js"
echo "Service URL injected: $SERVICE_URL"

# Inject expected RTMR2 from server image metadata into the bundle.
# Build fails if RTMR2 is not recorded — the client requires it.
RTMR2_VALUE=""
if [ -f "$SERVER_META" ]; then
  RTMR2_VALUE=$(grep "^RTMR2=" "$SERVER_META" | cut -d= -f2)
fi
if [[ "$RTMR2_VALUE" =~ ^[0-9a-fA-F]{96}$ ]]; then
  sed -i "s/\"__RTMR2_SENTINEL__\"/\"$RTMR2_VALUE\"/" "$PROJECT_DIR/bundle.js"
  echo "RTMR2 injected: $RTMR2_VALUE"
else
  echo "ERROR: RTMR2 not set in $SERVER_META — run record-rtmr2.sh first"
  exit 1
fi

# Download Ubuntu cloud image if not present
if [ ! -f "$CLOUD_IMAGE" ]; then
  echo "Downloading Ubuntu 24.04 cloud image..."
  wget -q --show-progress -O "$CLOUD_IMAGE" "$CLOUD_IMAGE_URL"
fi

# Create overlay disk (copy-on-write, base image stays clean)
echo "Creating VM disk overlay..."
rm -f "$DISK"
qemu-img create -f qcow2 -b "$CLOUD_IMAGE" -F qcow2 "$DISK" 4G

# Pack web content into a data ISO
echo "Creating web content ISO..."
WEBSTAGING=$(mktemp -d)
cp "$PROJECT_DIR"/index.html \
   "$PROJECT_DIR"/bundle.js \
   "$PROJECT_DIR"/parent.html \
   "$PROJECT_DIR"/browser-client.js \
   "$PROJECT_DIR"/tdx-quote-verifier.js \
   "$PROJECT_DIR"/utils.js \
   "$WEBSTAGING"/
rm -f "$WEBROOT"
genisoimage -quiet -o "$WEBROOT" -V WEBROOT -r -J "$WEBSTAGING"
rm -rf "$WEBSTAGING"

# Create cloud-init seed ISO
# Note: heredoc uses single quotes to protect nginx $uri literals.
# Placeholders (DOMAIN_PLACEHOLDER etc.) are substituted by sed after the heredoc.
cat > /tmp/ci-user-data <<'USERDATA'
#cloud-config
password: ubuntu
chpasswd:
  expire: false
ssh_pwauth: false

packages:
  - nginx
  - ufw
  - unattended-upgrades
  - openssl
  - certbot
  - python3-certbot-dns-cloudflare

write_files:
  - path: /etc/letsencrypt/cloudflare.ini
    permissions: '0600'
    content: |
      dns_cloudflare_api_token = CF_TOKEN_PLACEHOLDER

  - path: /usr/local/bin/setup-tls.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      set -euo pipefail
      exec >> /var/log/setup-tls.log 2>&1

      DOMAIN="DOMAIN_PLACEHOLDER"
      LE_EMAIL="LE_EMAIL_PLACEHOLDER"
      STAGING="STAGING_PLACEHOLDER"
      LE_LIVE="/etc/letsencrypt/live/$DOMAIN"
      SSL_DIR="/etc/nginx/ssl"

      log() { echo "[$(date -Iseconds)] $*"; }
      log "=== setup-tls.sh starting ==="

      mkdir -p "$SSL_DIR"

      # Generate self-signed fallback cert if nothing exists yet
      if [ ! -f "$SSL_DIR/server.crt" ]; then
          log "Generating self-signed fallback cert..."
          openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
              -keyout "$SSL_DIR/server.key" \
              -out "$SSL_DIR/server.crt" \
              -subj "/CN=$DOMAIN"
          chmod 600 "$SSL_DIR/server.key"
      fi

      # Start nginx if not running (can serve with self-signed while certbot runs)
      systemctl is-active --quiet nginx || systemctl start nginx

      # If LE cert already exists on disk (persistent overlay), just attempt renewal
      if [ -d "$LE_LIVE" ] && [ -f "$LE_LIVE/fullchain.pem" ]; then
          log "Existing LE cert found. Running certbot renew..."
          certbot renew --quiet \
              --deploy-hook /usr/local/bin/deploy-le-cert.sh
          log "Renewal check complete."
          exit 0
      fi

      # First issuance — build certbot args
      log "No LE cert found. Requesting certificate..."
      CERTBOT_ARGS=(
          certonly
          --non-interactive
          --agree-tos
          --email "$LE_EMAIL"
          --dns-cloudflare
          --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini
          --dns-cloudflare-propagation-seconds 60
          -d "$DOMAIN"
      )
      [ "$STAGING" = "true" ] && CERTBOT_ARGS+=(--staging) && log "Mode: STAGING"
      [ "$STAGING" != "true" ] && log "Mode: PRODUCTION"

      if certbot "${CERTBOT_ARGS[@]}"; then
          log "Certificate obtained successfully."
          /usr/local/bin/deploy-le-cert.sh
      else
          log "ERROR: certbot failed. Running with self-signed cert. Check /var/log/letsencrypt/"
          exit 0   # VM remains usable; exit 0 avoids systemd restart loop
      fi
      log "=== setup-tls.sh completed ==="

  - path: /usr/local/bin/deploy-le-cert.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      set -euo pipefail
      exec >> /var/log/setup-tls.log 2>&1

      DOMAIN="DOMAIN_PLACEHOLDER"
      LE_LIVE="/etc/letsencrypt/live/$DOMAIN"
      SSL_DIR="/etc/nginx/ssl"

      log() { echo "[$(date -Iseconds)] deploy-hook: $*"; }

      [ -f "$LE_LIVE/fullchain.pem" ] || { log "ERROR: cert not found"; exit 1; }

      log "Deploying LE cert..."
      ln -sf "$LE_LIVE/fullchain.pem" "$SSL_DIR/server.crt"
      ln -sf "$LE_LIVE/privkey.pem"   "$SSL_DIR/server.key"
      nginx -t && systemctl reload nginx
      log "nginx reloaded with LE cert."

  - path: /etc/systemd/system/setup-tls.service
    content: |
      [Unit]
      Description=Obtain or renew Let's Encrypt TLS certificate
      After=network-online.target
      Wants=network-online.target

      [Service]
      Type=oneshot
      ExecStart=/usr/local/bin/setup-tls.sh
      RemainAfterExit=yes

      [Install]
      WantedBy=multi-user.target

  - path: /usr/local/bin/update-crl.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      CRL_URL="https://api.trustedservices.intel.com/sgx/certification/v3/pckcrl?ca=platform&encoding=der"
      TMP=$(mktemp)
      curl -sf "$CRL_URL" -o "$TMP"
      if [ -s "$TMP" ]; then
          CRL_B64=$(base64 -w 0 "$TMP")
          CRL_DATE=$(openssl crl -in "$TMP" -inform DER -noout -lastupdate 2>/dev/null | sed 's/lastUpdate=//')
          printf 'window.EMBEDDED_CRL = "%s";\n' "$CRL_B64" > /var/www/html/crl.js
          printf 'window.EMBEDDED_CRL_DATE = "%s";\n' "$CRL_DATE" >> /var/www/html/crl.js
      fi
      rm -f "$TMP"

  - path: /etc/systemd/system/update-crl.service
    content: |
      [Unit]
      Description=Fetch updated Intel Platform CRL
      After=network-online.target
      Wants=network-online.target

      [Service]
      Type=oneshot
      ExecStart=/usr/local/bin/update-crl.sh

  - path: /etc/systemd/system/update-crl.timer
    content: |
      [Unit]
      Description=Weekly Intel Platform CRL refresh

      [Timer]
      OnBootSec=1min
      OnUnitActiveSec=7d

      [Install]
      WantedBy=timers.target

  - path: /etc/nginx/sites-available/default
    content: |
      server {
          listen 443 ssl default_server;
          listen [::]:443 ssl default_server;

          server_name DOMAIN_PLACEHOLDER;

          ssl_certificate     /etc/nginx/ssl/server.crt;
          ssl_certificate_key /etc/nginx/ssl/server.key;
          ssl_protocols TLSv1.2 TLSv1.3;
          ssl_ciphers HIGH:!aNULL:!MD5;

          server_tokens off;
          root /var/www/html;
          index index.html;

          add_header X-Content-Type-Options nosniff;
          add_header X-Frame-Options SAMEORIGIN;
          add_header X-XSS-Protection "1; mode=block";
          add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;

          location / {
              try_files $uri $uri/ =404;
          }
      }

runcmd:
  - mkdir -p /mnt/webdata
  - mount -o ro /dev/disk/by-label/WEBROOT /mnt/webdata
  - cp /mnt/webdata/* /var/www/html/
  - umount /mnt/webdata
  # Remove SSH entirely — not needed and reduces attack surface
  - apt-get purge -y openssh-server
  - apt-get autoremove -y
  # Enable automatic security updates
  - systemctl enable unattended-upgrades
  - systemctl start unattended-upgrades
  # TLS: generate self-signed fallback + obtain LE cert via DNS-01
  - systemctl daemon-reload
  - systemctl enable setup-tls.service
  - systemctl start setup-tls.service   # blocks cloud-init until cert is obtained
  - systemctl enable nginx
  # Enable certbot's built-in renewal timer (runs certbot renew twice daily)
  # This keeps the cert valid on a long-running VM (LE certs expire in 90 days)
  - systemctl enable certbot.timer
  - systemctl start certbot.timer
  # CRL auto-refresh
  - systemctl enable update-crl.timer
  - systemctl start update-crl.timer
  # Fetch CRL immediately so it's available on first load
  - /usr/local/bin/update-crl.sh
  # Firewall — HTTPS only, no port 80 needed (DNS-01 uses no inbound ports)
  - ufw default deny incoming
  - ufw default allow outgoing
  - ufw allow 443/tcp
  - ufw --force enable
  # Lock out password login on console too
  - passwd -l ubuntu
  - passwd -l root
USERDATA

# Substitute placeholders with actual values
sed -i \
  -e "s|DOMAIN_PLACEHOLDER|${DOMAIN}|g" \
  -e "s|LE_EMAIL_PLACEHOLDER|${LE_EMAIL}|g" \
  -e "s|CF_TOKEN_PLACEHOLDER|${CF_API_TOKEN}|g" \
  -e "s|STAGING_PLACEHOLDER|${LETSENCRYPT_STAGING}|g" \
  /tmp/ci-user-data

cat > /tmp/ci-meta-data <<'METADATA'
instance-id: webserver-vm
local-hostname: webserver
METADATA

rm -f "$SEED"
cloud-localds "$SEED" /tmp/ci-user-data /tmp/ci-meta-data
rm -f /tmp/ci-user-data /tmp/ci-meta-data

echo ""
echo "Build complete ($MODE). Files: $DISK, $SEED, $WEBROOT"
echo "Run: ./boot.sh --$MODE"
