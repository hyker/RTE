# Domain the client VM serves on, and the Let's Encrypt account email.
# Mirrors server/build-config.sh. Both dev and prod use this same domain —
# they differ only by port (9445 / 8445) and by dev using LE staging certs.
#
# Changing DOMAIN requires a rebuild of this VM (./build.sh) — see the DNS
# section of the top-level README.
DOMAIN="rteverif.xyz"
LE_EMAIL="joakim.brorsson@hyker.se"
