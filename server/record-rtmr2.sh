#!/bin/bash
# Boot the VM, query /measurements, write the values into the image .meta file, then stop the VM.
# Run this after setup-verity.sh and before building the client bundle.
# The top-level build.sh runs this automatically; use standalone only if needed.
#
# Records MRTD, RTMR0, RTMR1 and RTMR2 (the script name is kept for compatibility
# with build.sh and the README). RTMR3 and the TD debug bit are deliberately not
# recorded — the client checks those as invariants, with no expected value.
#
# The boot uses `boot.sh --measure-only`, so no Let's Encrypt certificate is spent.
# Values are sanity-checked by client/vm/build.sh before they are baked into the bundle.
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

# .meta keys paired with their /measurements JSON key.
META_KEYS=(MRTD RTMR0 RTMR1 RTMR2)
JSON_KEYS=(mrTd rtmr0 rtmr1 rtmr2)

meta_get() { grep "^$1=" "$META" | cut -d= -f2; }
json_field() { echo "$1" | grep -o "\"$2\":\"[^\"]*\"" | cut -d'"' -f4; }

# Skip only if every value is already recorded.
ALL_SET=true
for key in "${META_KEYS[@]}"; do
  [ -z "$(meta_get "$key")" ] && ALL_SET=false
done
if [ "$ALL_SET" = true ]; then
  echo "All measurements already set in $META. To re-record, clear those lines first."
  for key in "${META_KEYS[@]}"; do echo "  $key=$(meta_get "$key")"; done
  exit 0
fi

echo "Booting VM ($MODE, measure-only) to record measurements..."
# Kill any stale VM from a previous run to free the port
pkill -f "process=$VM_NAME" 2>/dev/null || true
sleep 1
./boot.sh --"$MODE" --measure-only

cleanup() {
  echo "Stopping VM..."
  pkill -f "process=$VM_NAME" 2>/dev/null || true
}
trap cleanup EXIT

echo "Waiting for custodes on port $PORT (up to 5 min)..."
TIMEOUT=300
ELAPSED=0
RESPONSE=""
while [ $ELAPSED -lt $TIMEOUT ]; do
  RESPONSE=$(curl -sk --max-time 5 "https://localhost:$PORT/measurements" 2>/dev/null || true)
  [ -n "$(json_field "$RESPONSE" rtmr2)" ] && break
  RESPONSE=""
  sleep 5
  ELAPSED=$((ELAPSED + 5))
  printf "  ...%ds\n" "$ELAPSED"
done

if [ -z "$RESPONSE" ]; then
  echo "Error: no valid response from /measurements within ${TIMEOUT}s"
  exit 1
fi

for i in "${!META_KEYS[@]}"; do
  VALUE=$(json_field "$RESPONSE" "${JSON_KEYS[$i]}")
  sed -i "s/^${META_KEYS[$i]}=.*/${META_KEYS[$i]}=$VALUE/" "$META"
  echo "  ${META_KEYS[$i]}=$VALUE"
done

echo "Measurements written to $META"
