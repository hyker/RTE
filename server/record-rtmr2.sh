#!/bin/bash
# Boot the VM, query /rtmr2, write the value into the image .meta file, then stop the VM.
# Run this after setup-verity.sh and before building the client bundle.
# The top-level build.sh runs this automatically; use standalone only if needed.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

MODE="prod"
while [[ $# -gt 0 ]]; do
  case $1 in
    --prod) MODE="prod"; shift ;;
    --dev)  MODE="dev";  shift ;;
    *) echo "Usage: $0 [--prod|--dev]"; exit 1 ;;
  esac
done

case $MODE in
  prod) META="verity-image.img.meta";     PORT=8444; VM_NAME="verity-prod" ;;
  dev)  META="verity-dev-image.img.meta"; PORT=9444; VM_NAME="verity-dev" ;;
esac

if [ ! -f "$META" ]; then
  echo "Error: $META not found. Run setup-verity.sh first."
  exit 1
fi

EXISTING=$(grep "^RTMR2=" "$META" | cut -d= -f2)
if [ -n "$EXISTING" ]; then
  echo "RTMR2 already set in $META: $EXISTING"
  echo "To re-record, clear the RTMR2= line in $META first."
  exit 0
fi

echo "Booting VM ($MODE) to record RTMR2..."
./boot.sh --$MODE

cleanup() {
  echo "Stopping VM..."
  pkill -f "process=$VM_NAME" 2>/dev/null || true
}
trap cleanup EXIT

echo "Waiting for custodes on port $PORT (up to 5 min)..."
TIMEOUT=300
ELAPSED=0
RTMR2_HEX=""
while [ $ELAPSED -lt $TIMEOUT ]; do
  RESPONSE=$(curl -sk --max-time 5 "https://localhost:$PORT/rtmr2" 2>/dev/null || true)
  if [ -n "$RESPONSE" ]; then
    RTMR2_HEX=$(echo "$RESPONSE" | grep -o '"rtmr2":"[^"]*"' | cut -d'"' -f4)
    if [[ "$RTMR2_HEX" =~ ^[0-9a-fA-F]{96}$ ]]; then
      break
    fi
  fi
  sleep 5
  ELAPSED=$((ELAPSED + 5))
  printf "  ...%ds\n" "$ELAPSED"
done

if [[ ! "$RTMR2_HEX" =~ ^[0-9a-fA-F]{96}$ ]]; then
  echo "Error: failed to get a valid RTMR2 within ${TIMEOUT}s"
  exit 1
fi

sed -i "s/^RTMR2=.*/RTMR2=$RTMR2_HEX/" "$META"

echo "RTMR2 recorded: $RTMR2_HEX"
echo "Written to $META"
