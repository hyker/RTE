#!/bin/bash
# Boot server and client VMs
# Usage: ./boot.sh <dev|prod> [--measure-only]
set -e

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

usage() {
  cat <<USAGE
Usage: $0 <dev|prod> [--measure-only]

Boots the server VM and then the client hosting VM for the given mode.
Mode may be given as 'dev'/'prod' or '--dev'/'--prod'.

  --measure-only   Server boots with a self-signed certificate and never
                   contacts Let's Encrypt, so the boot costs no certificate.
                   Passed through to server/boot.sh; the client VM is not started.
USAGE
}

MODE=""
MEASURE_ONLY=""
while [[ $# -gt 0 ]]; do
  case ${1#--} in
    dev|prod)      MODE="${1#--}";           shift ;;
    measure-only)  MEASURE_ONLY="--measure-only"; shift ;;
    help|h)        usage; exit 0 ;;
    *)             usage >&2; exit 1 ;;
  esac
done

if [ -z "$MODE" ]; then
  usage >&2
  exit 1
fi

(cd "$REPO_ROOT/server" && ./boot.sh --"$MODE" $MEASURE_ONLY)

if [ -n "$MEASURE_ONLY" ]; then
  echo "Measure-only boot: client VM not started."
  exit 0
fi

(cd "$REPO_ROOT/client/vm" && ./boot.sh --"$MODE")
