#!/bin/bash
# Kill running VMs (server and client)
# Usage: ./kill.sh <dev|prod>
set -e

if [ -z "$1" ]; then
  echo "Usage: $0 <dev|prod>"
  exit 1
fi

MODE="$1"
REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

case $MODE in
  dev)
    pkill -f 'process=verity-dev' && echo "Killed dev server" || echo "Dev server not running"
    pkill -f 'process=quote-verifier-dev' && echo "Killed dev client" || echo "Dev client not running"
    rm -f "$REPO_ROOT/server/verity-dev-overlay.img"
    ;;
  prod)
    pkill -f 'process=verity-prod' && echo "Killed prod server" || echo "Prod server not running"
    pkill -f 'process=quote-verifier-prod' && echo "Killed prod client" || echo "Prod client not running"
    ;;
  *)
    echo "Usage: $0 <dev|prod>"
    exit 1
    ;;
esac
