#!/bin/bash
set -euo pipefail
exec >>/var/log/tls-provision.log 2>&1

log() { echo "[$(date -Iseconds)] $*"; }

CERT=/run/custodes/tls/cert.pem

# Check if cert expires within 30 days
if openssl x509 -checkend $((30 * 86400)) -noout -in "$CERT" 2>/dev/null; then
    log "Renewal check: cert valid for >30 days, skipping"
    exit 0
fi

log "Renewal check: cert expires within 30 days — renewing"
/usr/local/bin/tls-provision.sh
systemctl restart custodes.service
log "Custodes restarted with renewed cert"
