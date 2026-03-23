#!/bin/bash
# Boot server and client VMs
# Usage: ./boot.sh <dev|prod>
set -e

if [ -z "$1" ]; then
  echo "Usage: $0 <dev|prod>"
  exit 1
fi

MODE="$1"
REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

case $MODE in
  dev|prod)
    (cd "$REPO_ROOT/server" && ./boot.sh --$MODE)
    (cd "$REPO_ROOT/client/vm" && ./boot.sh --$MODE)
    ;;
  *)
    echo "Usage: $0 <dev|prod>"
    exit 1
    ;;
esac
