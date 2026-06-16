#!/bin/bash
# Kill running verity VMs
# Usage: ./kill-vm.sh <dev|prod|all>

if [ -z "$1" ]; then
  echo "Usage: $0 <dev|prod|all>"
  exit 1
fi

MODE="$1"

case $MODE in
  dev)
    pkill -f 'process=verity-dev' && echo "Killed dev VM" || echo "Dev VM not running"
    rm -f verity-dev-overlay.img
    ;;
  prod)
    pkill -f 'process=verity-prod' && echo "Killed prod VM" || echo "Prod VM not running"
    ;;
  all)
    pkill -f 'process=verity-dev' && echo "Killed dev VM" || echo "Dev VM not running"
    pkill -f 'process=verity-prod' && echo "Killed prod VM" || echo "Prod VM not running"
    rm -f verity-dev-overlay.img
    ;;
  *)
    echo "Usage: $0 [dev|prod|all]"
    exit 1
    ;;
esac
