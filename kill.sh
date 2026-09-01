#!/bin/bash
# Kill running VMs (server and client)
# Usage: ./kill.sh <dev|prod|all>
set -e

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

usage() {
  cat <<USAGE
Usage: $0 <dev|prod|all>

Kills the server and client VMs for the given mode. 'all' kills both modes.
Mode may be given as 'dev'/'prod' or '--dev'/'--prod'.
USAGE
}

kill_mode() {
  local m="$1"
  pkill -f "process=verity-$m"          && echo "Killed $m server" || echo "$m server not running"
  pkill -f "process=quote-verifier-$m"  && echo "Killed $m client" || echo "$m client not running"
  [ "$m" = "dev" ] && rm -f "$REPO_ROOT/server/verity-dev-overlay.img"
  return 0
}

case ${1#--} in
  dev|prod) kill_mode "${1#--}" ;;
  all)      kill_mode dev; kill_mode prod ;;
  help|h)   usage; exit 0 ;;
  *)        usage >&2; exit 1 ;;
esac
