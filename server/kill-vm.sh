#!/bin/bash
# Kill running verity VMs
# Usage: ./kill-vm.sh <dev|prod|all>

usage() {
  echo "Usage: $0 <dev|prod|all>"
  echo "  Kills the server VM(s) only. Mode may be 'dev'/'prod' or '--dev'/'--prod'."
  echo "  Use ../kill.sh to kill the client VM as well."
}

if [ -z "$1" ]; then
  usage >&2
  exit 1
fi

MODE="${1#--}"

case $MODE in
  help|h) usage; exit 0 ;;
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
    usage >&2
    exit 1
    ;;
esac
