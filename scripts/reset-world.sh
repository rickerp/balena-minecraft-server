#!/usr/bin/env bash
# Delete the Minecraft world on the balena device and let Paper generate a new one.
# Keeps server.properties (hardcore, difficulty, seed), the whitelist, ops and plugins.
# Asks first whether to save a backup of the old world to ~/Downloads.
#
# Usage: scripts/reset-world.sh [--backup | --no-backup] [-y]
#   --backup     save a backup without asking
#   --no-backup  don't save a backup, without asking
#   -y           don't ask anything (no backup unless --backup is also given)
# Env: BALENA_DEVICE (default eb85bb9), PI_HOST (default: the device's LAN IP from balena)
#
# Asks once for the scp-server SSH password (SCP_PASSWORD, default "balena").

set -euo pipefail

DEVICE=${BALENA_DEVICE:-eb85bb9}
SERVICE=mc-server
PORT=25565
BACKUP=ask
ASSUME_YES=false

for arg in "$@"; do
  case "$arg" in
    --backup) BACKUP=yes ;;
    --no-backup) BACKUP=no ;;
    -y | --yes) ASSUME_YES=true ;;
    -h | --help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg (see --help)" >&2; exit 2 ;;
  esac
done

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

# balena CLI prints a Node.js version warning on stderr, so hide stderr
bal() { balena "$@" 2>/dev/null; }

# Run "$@" every 2 s until it succeeds; give up after $2 seconds
wait_for() {
  local what=$1 limit=$2 start=$SECONDS
  shift 2
  until "$@"; do
    ((SECONDS - start < limit)) || die "timed out waiting for $what"
    sleep 2
  done
}

port_open() { nc -z -w 3 "$PI_HOST" "$PORT" >/dev/null 2>&1; }
port_closed() { ! port_open; }

command -v balena >/dev/null || die "balena CLI not found (brew install balena-cli)"

if [[ -z "${PI_HOST:-}" ]]; then
  PI_HOST=$(bal device "$DEVICE" --json | python3 -c '
import json, sys
ips = json.load(sys.stdin)["ip_address"].split()
print(next(ip for ip in ips if "." in ip))
') || die "could not get the IP of device $DEVICE from balena (logged in? try: balena login)"
fi

if [[ "$BACKUP" == ask ]]; then
  if $ASSUME_YES; then
    BACKUP=no
  else
    read -r -p "Save a backup of the current world to ~/Downloads first? [y/N] " answer
    case "$answer" in
      [yY] | [yY][eE][sS]) BACKUP=yes ;;
      *) BACKUP=no ;;
    esac
  fi
fi

if ! $ASSUME_YES; then
  if [[ "$BACKUP" == yes ]]; then
    echo "This deletes the Minecraft world on $PI_HOST after saving a backup to ~/Downloads."
  else
    echo "This permanently deletes the Minecraft world on $PI_HOST. No backup is saved."
  fi
  echo "Everyone online is disconnected for about 2 minutes."
  read -r -p "Type RESET to continue: " answer
  [[ "$answer" == "RESET" ]] || die "cancelled, nothing changed"
fi

# One SSH connection, reused by every command below, so the password is asked once
SOCK_DIR=$(mktemp -d /tmp/mc-reset.XXXXXX)
SSH=(ssh -o ControlPath="$SOCK_DIR/ssh" "root@$PI_HOST")
SERVICE_STOPPED=false
cleanup() {
  # If the script fails or is interrupted after stopping the server, start it again
  if $SERVICE_STOPPED; then
    echo "Starting $SERVICE again because the reset did not finish" >&2
    bal device start-service "$DEVICE" "$SERVICE" >/dev/null ||
      echo "Could not start $SERVICE. Start it from the balena dashboard." >&2
  fi
  ssh -o ControlPath="$SOCK_DIR/ssh" -O exit "root@$PI_HOST" >/dev/null 2>&1 || true
  rm -rf "$SOCK_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

say "Connecting to $PI_HOST (password: SCP_PASSWORD, default balena)"
ssh -o ControlMaster=yes -o ControlPersist=15m -o ControlPath="$SOCK_DIR/ssh" \
  -o StrictHostKeyChecking=accept-new "root@$PI_HOST" true ||
  die "SSH login failed. If it says the host key changed, run: ssh-keygen -R $PI_HOST"

LEVEL=$("${SSH[@]}" "sed -n 's/^level-name=//p' /serverfiles/server.properties")
LEVEL=${LEVEL:-world}
[[ "$LEVEL" =~ ^[A-Za-z0-9._-]+$ && "$LEVEL" != "." && "$LEVEL" != ".." ]] ||
  die "unexpected level-name '$LEVEL' in server.properties"

# True when Paper's log has not changed for 10 s, which means it has finished saving
log_quiet() {
  local now mtime
  read -r now mtime < <("${SSH[@]}" 'echo "$(date +%s) $(stat -c %Y /serverfiles/logs/latest.log 2>/dev/null || echo 0)"')
  ((now - mtime >= 10))
}

say "Stopping $SERVICE (Paper saves the world before it exits)"
bal device stop-service "$DEVICE" "$SERVICE" >/dev/null || die "could not stop $SERVICE"
SERVICE_STOPPED=true
wait_for "the server port to close" 120 port_closed
wait_for "Paper to finish saving" 120 log_quiet

if [[ "$BACKUP" == yes ]]; then
  out=~/Downloads/minecraft-world-$(date +%Y-%m-%d-%H%M).tar.gz
  say "Saving the old world to $out"
  if ! "${SSH[@]}" "tar -C /serverfiles -czf - '$LEVEL'" >"$out" || ! tar -tzf "$out" >/dev/null 2>&1; then
    rm -f "$out"
    die "the backup failed, so the world was not deleted"
  fi
  echo "    Saved $(du -h "$out" | awk '{print $1}')"
fi

say "Deleting /serverfiles/$LEVEL"
"${SSH[@]}" "rm -rf '/serverfiles/$LEVEL'"
sleep 5
if ! "${SSH[@]}" "test ! -e '/serverfiles/$LEVEL'"; then
  SERVICE_STOPPED=false
  die "the world folder came back, so $SERVICE may still be running. It was not started again."
fi

echo "    New world settings:"
"${SSH[@]}" "grep -E '^(hardcore|difficulty|level-seed)=' /serverfiles/server.properties" | sed 's/^/      /'

say "Starting $SERVICE (a new world takes 1-2 minutes)"
bal device start-service "$DEVICE" "$SERVICE" >/dev/null || die "could not start $SERVICE"
SERVICE_STOPPED=false
wait_for "the server to come up" 300 port_open

say "Done. The new world is up at $PI_HOST:$PORT"
