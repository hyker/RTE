#!/bin/bash
# Full build pipeline: server image → dm-verity → RTMR2 → client bundle
# Usage: ./build.sh --prod|--dev [--debug]
#
# Individual steps can also be run standalone — see server/README.md.
set -e

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

MODE=""
TDX_FLAG=""
DEBUG_FLAG=""
usage() {
  echo "Usage: $0 <--prod|--dev> [--tdx] [--debug]"
  echo "  --prod   Build production image"
  echo "  --dev    Build dev image"
  echo "  --tdx    Enable TDX attestation support (required for measurement recording)"
  echo "  --debug  Keep SSH and console login in the image (never for production)"
  echo ""
  echo "Mode may be given as '--dev'/'--prod' or 'dev'/'prod'. There is no default."
}

while [[ $# -gt 0 ]]; do
  case ${1#--} in
    prod)   MODE="prod";           shift ;;
    dev)    MODE="dev";            shift ;;
    tdx)    TDX_FLAG="--tdx";      shift ;;
    debug)  DEBUG_FLAG="--debug";  shift ;;
    help|h) usage; exit 0 ;;
    *)      usage >&2; exit 1 ;;
  esac
done

if [ -z "$MODE" ]; then
  usage >&2
  exit 1
fi

cd "$REPO_ROOT/server"

echo "=== Step 1/4: Build server base image ==="
./build-base.sh --$MODE $TDX_FLAG $DEBUG_FLAG

echo ""
echo "=== Step 2/4: Setup dm-verity ==="
sudo ./setup-verity.sh --$MODE

echo ""
echo "=== Step 3/4: Record RTMR2 from live boot ==="
./record-rtmr2.sh --$MODE

echo ""
echo "=== Step 4/4: Build client bundle ==="
(cd "$REPO_ROOT/client/vm" && ./build.sh --$MODE)

echo ""
echo "Build complete ($MODE)."
echo ""
echo "Start server:  cd server && ./boot.sh --$MODE"
echo "Start client:  cd client/vm && ./boot.sh --$MODE"
