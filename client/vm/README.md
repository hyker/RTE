# Client hosting VM

QEMU/KVM VM serving the browser client over HTTPS with nginx. Prod listens on 8445, dev on 9445;
both use the same domain, and dev takes a Let's Encrypt *staging* certificate so iterating costs
no production rate limit.

## Prerequisites

- Domain on Cloudflare DNS with an A record pointing to the host IP
- Cloudflare API token scoped to `Zone → DNS → Edit` for that zone
- Token in `vm/secrets.sh` (untracked):
  ```bash
  echo 'CF_API_TOKEN="your-token-here"' > vm/secrets.sh
  ```
- The server image must already be built and measured — `build.sh` reads the four expected
  measurements out of `server/verity-image.img.meta` (prod) or `verity-dev-image.img.meta` (dev)
  and refuses to build if any is missing.

## Build and run

```bash
./build.sh --prod && ./boot.sh --prod    # https://<domain>:8445
./build.sh --dev  && ./boot.sh --dev     # https://<domain>:9445, LE staging cert

# Stop:
pkill -f 'process=quote-verifier-prod'   # or quote-verifier-dev
```

`build.sh` recreates the VM disk from the Ubuntu cloud image every run, so each build is clean.
**Rebuild rather than reboot** — booting an existing disk re-serves the webroot cloud-init already
copied, which means a stale bundle with stale measurements.

On first boot certbot obtains the certificate via Cloudflare DNS-01, and `certbot.timer` handles
renewal. No inbound ports are needed for issuance — only outbound to the Cloudflare API and Let's
Encrypt. If certbot fails the VM stays up on its self-signed fallback rather than restart-looping,
so **check the certificate after any DNS or domain change** — failure is silent.

## Configuration

`build-config.sh` (tracked): `DOMAIN`, `LE_EMAIL`.
`secrets.sh` (untracked): `CF_API_TOKEN`.
Staging vs production certificates follows `--dev` / `--prod`; it is not a separate setting.
