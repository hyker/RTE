# VM

QEMU/KVM VM serving the browser client over HTTPS on port 8445.

## Prerequisites

- Domain on Cloudflare DNS with an A record pointing to the host IP
- Cloudflare API token scoped to `Zone → DNS → Edit` for the zone
- Token in `vm/secrets.sh` (gitignored):
  ```bash
  echo 'CF_API_TOKEN="your-token-here"' > vm/secrets.sh
  ```

## Build and run

```bash
cd vm && ./build.sh && ./boot.sh
# Stop: pkill -f 'process=quote-verifier-web'
```

On first boot, certbot obtains a Let's Encrypt cert via Cloudflare DNS-01.
No inbound ports needed — only outbound to Cloudflare API and Let's Encrypt.
`certbot.timer` renews automatically every ~60 days.

## Staging (test cert without consuming production rate limits)

```bash
cd vm && bash build-staging.sh && ./boot-staging.sh   # port 8446
# Stop: pkill -f 'process=quote-verifier-staging'
```

Set `LETSENCRYPT_STAGING="true"` in `build-staging.sh` while iterating,
then `"false"` once confirmed working.

## Configuration

Edit the variables at the top of `build.sh` / `build-staging.sh`:
`DOMAIN`, `LE_EMAIL`, `LETSENCRYPT_STAGING`. `CF_API_TOKEN` comes from `secrets.sh`.
