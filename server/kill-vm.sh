#!/bin/bash
# Kill running verity VMs
# Usage: ./kill-vm.sh <dev|staging|all>

if [ -z "$1" ]; then
  echo "Usage: $0 <dev|staging|all>"
  exit 1
fi

MODE="$1"

case $MODE in
  dev)
    pkill -f 'process=verity-dev' && echo "Killed dev VM" || echo "Dev VM not running"
    rm -f verity-dev-overlay.img
    ;;
  staging)
    pkill -f 'process=verity-staging' && echo "Killed staging VM" || echo "Staging VM not running"
    ;;
  all)
    pkill -f 'process=verity-dev' && echo "Killed dev VM" || echo "Dev VM not running"
    pkill -f 'process=verity-staging' && echo "Killed staging VM" || echo "Staging VM not running"
    rm -f verity-dev-overlay.img
    ;;
  *)
    echo "Usage: $0 [dev|staging|all]"
    exit 1
    ;;
esac
