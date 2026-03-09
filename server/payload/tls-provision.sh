#!/bin/bash
set -euo pipefail
exec >>/var/log/tls-provision.log 2>&1

log() { echo "[$(date -Iseconds)] $*"; }
log "=== tls-provision starting ==="

source /opt/certbot/certbot.env   # LE_DOMAIN, LE_EMAIL, LE_STAGING — from image

TLS_DIR=/run/custodes/tls
mkdir -p "$TLS_DIR"
chmod 700 "$TLS_DIR"

# Self-signed cert+key fallback function
make_self_signed() {
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
        -keyout "$TLS_DIR/key.pem" -out "$TLS_DIR/cert.pem" \
        -days 1 -subj "/CN=$LE_DOMAIN" -nodes 2>/dev/null
    chmod 600 "$TLS_DIR/key.pem"
    echo "self-signed-fallback" > "$TLS_DIR/source"
}

# CF API token from fw_cfg
FW_CFG_INI=/sys/firmware/qemu_fw_cfg/by_name/opt/certbot/cloudflare-ini/raw
if [ ! -r "$FW_CFG_INI" ]; then
    log "fw_cfg cloudflare-ini not found — self-signed fallback"
    make_self_signed
    log "=== tls-provision done (self-signed-fallback — no fw_cfg) ==="
    exit 0
fi

mkdir -p /run/certbot && chmod 700 /run/certbot
cat "$FW_CFG_INI" > /run/certbot/cloudflare.ini
chmod 600 /run/certbot/cloudflare.ini

mkdir -p /var/log/letsencrypt

CERTBOT_ARGS=(
    certonly
    --non-interactive
    --agree-tos
    --email "$LE_EMAIL"
    --dns-cloudflare
    --dns-cloudflare-credentials /run/certbot/cloudflare.ini
    --dns-cloudflare-propagation-seconds 60
    --config-dir /run/certbot
    --logs-dir /var/log/letsencrypt
    --domain "$LE_DOMAIN"
)
[ "$LE_STAGING" = "true" ] && CERTBOT_ARGS+=(--staging) && log "Mode: STAGING"
[ "$LE_STAGING" != "true" ] && log "Mode: PRODUCTION (domain: $LE_DOMAIN)"

if certbot "${CERTBOT_ARGS[@]}"; then
    log "LE cert obtained."
    cp "/run/certbot/live/$LE_DOMAIN/fullchain.pem" "$TLS_DIR/cert.pem"
    cp "/run/certbot/live/$LE_DOMAIN/privkey.pem" "$TLS_DIR/key.pem"
    chmod 600 "$TLS_DIR/key.pem"
    echo "letsencrypt" > "$TLS_DIR/source"
else
    log "certbot failed — self-signed fallback"
    make_self_signed
fi
log "=== tls-provision done (source: $(cat $TLS_DIR/source)) ==="
