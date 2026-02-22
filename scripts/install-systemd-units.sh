#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYSTEMD_DIR="/etc/systemd/system"
SOURCE_DIR="$REPO_ROOT/contrib/systemd"

ALT_SERVICE_NAME="altserver-linux.service"
ANIS_SERVICE_NAME="altserver-anisette.service"
NETMUX_SERVICE_NAME="netmuxd.service"

ALT_PATH="/usr/local/bin/AltServer"
ANI_URL="http://127.0.0.1:6969"
NETMUX_BIN="/usr/local/bin/netmuxd"
NETMUX_SOCKET="127.0.0.1:27015"
WITH_NETMUXD="false"
ENABLE_NOW="false"

info() {
  printf '[INFO] %s\n' "$*"
}

fail() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

sudo_run() {
  if [[ "$EUID" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

usage() {
  cat <<USAGE
Install systemd units for AltServer-Linux.

Usage:
  $SCRIPT_NAME [options]

Options:
  --alt-path PATH         Path to AltServer binary (default: $ALT_PATH)
  --anisette-url URL      ALTSERVER_ANISETTE_SERVER value (default: $ANI_URL)
  --with-netmuxd          Install/start netmuxd service and wire AltServer to it
  --netmuxd-bin PATH      netmuxd binary path (default: $NETMUX_BIN)
  --netmuxd-socket ADDR   USBMUXD_SOCKET_ADDRESS host:port (default: $NETMUX_SOCKET)
  --enable-now            Enable and start services immediately
  -h, --help              Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --alt-path)
      shift
      [[ $# -gt 0 ]] || fail "Missing value for --alt-path"
      ALT_PATH="$1"
      ;;
    --anisette-url)
      shift
      [[ $# -gt 0 ]] || fail "Missing value for --anisette-url"
      ANI_URL="$1"
      ;;
    --with-netmuxd)
      WITH_NETMUXD="true"
      ;;
    --netmuxd-bin)
      shift
      [[ $# -gt 0 ]] || fail "Missing value for --netmuxd-bin"
      NETMUX_BIN="$1"
      ;;
    --netmuxd-socket)
      shift
      [[ $# -gt 0 ]] || fail "Missing value for --netmuxd-socket"
      NETMUX_SOCKET="$1"
      ;;
    --enable-now)
      ENABLE_NOW="true"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
  shift

done

[[ -f "$SOURCE_DIR/$ALT_SERVICE_NAME" ]] || fail "Missing template: $SOURCE_DIR/$ALT_SERVICE_NAME"
[[ -f "$SOURCE_DIR/$ANIS_SERVICE_NAME" ]] || fail "Missing template: $SOURCE_DIR/$ANIS_SERVICE_NAME"
[[ -x "$ALT_PATH" ]] || fail "AltServer binary not executable: $ALT_PATH"
if [[ "$WITH_NETMUXD" == "true" ]]; then
  [[ -f "$SOURCE_DIR/$NETMUX_SERVICE_NAME" ]] || fail "Missing template: $SOURCE_DIR/$NETMUX_SERVICE_NAME"
  [[ -x "$NETMUX_BIN" ]] || fail "netmuxd binary not executable: $NETMUX_BIN"
fi

tmp_alt="$(mktemp)"
tmp_netmux="$(mktemp)"
trap 'rm -f "$tmp_alt" "$tmp_netmux"' EXIT

sed -e "s|^ExecStart=/usr/local/bin/AltServer.*$|ExecStart=${ALT_PATH} -d -d|" \
    -e "s|^Environment=ALTSERVER_ANISETTE_SERVER=.*$|Environment=ALTSERVER_ANISETTE_SERVER=${ANI_URL}|" \
    "$SOURCE_DIR/$ALT_SERVICE_NAME" > "$tmp_alt"

if [[ "$WITH_NETMUXD" == "true" ]]; then
  sed -i -e "s|^After=.*$|After=network-online.target usbmuxd.service avahi-daemon.service altserver-anisette.service netmuxd.service|" \
         -e "s|^Wants=.*$|Wants=network-online.target usbmuxd.service avahi-daemon.service altserver-anisette.service netmuxd.service|" \
         "$tmp_alt"

  if ! grep -q '^Environment=USBMUXD_SOCKET_ADDRESS=' "$tmp_alt"; then
    sed -i "/^Environment=ALTSERVER_ANISETTE_SERVER=.*/a Environment=USBMUXD_SOCKET_ADDRESS=${NETMUX_SOCKET}" "$tmp_alt"
  fi

  sed -e "s|^ExecStart=/usr/local/bin/netmuxd.*$|ExecStart=${NETMUX_BIN} --disable-unix --host ${NETMUX_SOCKET%:*} --port ${NETMUX_SOCKET##*:}|" \
      "$SOURCE_DIR/$NETMUX_SERVICE_NAME" > "$tmp_netmux"
fi

info "Installing $ANIS_SERVICE_NAME"
sudo_run install -m 0644 "$SOURCE_DIR/$ANIS_SERVICE_NAME" "$SYSTEMD_DIR/$ANIS_SERVICE_NAME"

if [[ "$WITH_NETMUXD" == "true" ]]; then
  info "Installing $NETMUX_SERVICE_NAME"
  sudo_run install -m 0644 "$tmp_netmux" "$SYSTEMD_DIR/$NETMUX_SERVICE_NAME"
fi

info "Installing $ALT_SERVICE_NAME"
sudo_run install -m 0644 "$tmp_alt" "$SYSTEMD_DIR/$ALT_SERVICE_NAME"

info "Reloading systemd daemon"
sudo_run systemctl daemon-reload

if [[ "$ENABLE_NOW" == "true" ]]; then
  info "Enabling and starting $ANIS_SERVICE_NAME"
  sudo_run systemctl enable --now "$ANIS_SERVICE_NAME"
  if [[ "$WITH_NETMUXD" == "true" ]]; then
    info "Enabling and starting $NETMUX_SERVICE_NAME"
    sudo_run systemctl enable --now "$NETMUX_SERVICE_NAME"
  fi
  info "Enabling and starting $ALT_SERVICE_NAME"
  sudo_run systemctl enable --now "$ALT_SERVICE_NAME"
else
  info "Services installed. To enable later:"
  printf '  sudo systemctl enable --now %s\n' "$ANIS_SERVICE_NAME"
  if [[ "$WITH_NETMUXD" == "true" ]]; then
    printf '  sudo systemctl enable --now %s\n' "$NETMUX_SERVICE_NAME"
  fi
  printf '  sudo systemctl enable --now %s\n' "$ALT_SERVICE_NAME"
fi
