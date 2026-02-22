#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"

DEFAULT_BUILDER_IMAGE="ghcr.io/nyamisty/altserver_builder_alpine_amd64"
DEFAULT_LOCAL_BUILDER_IMAGE="altserver-builder-local"
DEFAULT_ANISETTE_IMAGE="dadoum/anisette-v3-server:latest"
DEFAULT_ANISETTE_CONTAINER="altserver-anisette"
DEFAULT_ANISETTE_PORT="6969"
DEFAULT_INSTALL_PATH="/usr/local/bin/AltServer"
DEFAULT_ALTSTORE_OUTPUT="$REPO_ROOT/AltStore.ipa"
DEFAULT_ALTSTORE_SOURCE_URL="https://cdn.altstore.io/file/altstore/apps.json"
DEFAULT_ALTSTORE_BUNDLE_ID="com.rileytestut.AltStore"
DEFAULT_NETMUXD_BIN="/usr/local/bin/netmuxd"
DEFAULT_NETMUXD_HOST="127.0.0.1"
DEFAULT_NETMUXD_PORT="27015"
DEFAULT_NETMUXD_PIDFILE="/tmp/netmuxd-altserver-linux.pid"
DEFAULT_NETMUXD_LOGFILE="/tmp/netmuxd-altserver-linux.log"

ANIS_KEYS=(
  "X-Apple-I-MD-M"
  "X-Apple-I-MD"
  "X-Apple-I-MD-LU"
  "X-Apple-I-MD-RINFO"
  "X-Mme-Device-Id"
  "X-Apple-I-SRL-NO"
  "X-MMe-Client-Info"
  "X-Apple-I-Client-Time"
  "X-Apple-Locale"
  "X-Apple-I-TimeZone"
)

info() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

fail() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

default_mux_socket() {
  printf '%s:%s\n' "$DEFAULT_NETMUXD_HOST" "$DEFAULT_NETMUXD_PORT"
}

split_socket_address() {
  local addr="$1"
  local host="${addr%:*}"
  local port="${addr##*:}"

  [[ -n "$host" ]] || fail "Invalid socket address (missing host): $addr"
  [[ "$port" =~ ^[0-9]+$ ]] || fail "Invalid socket address (bad port): $addr"
  [[ "$port" -ge 1 && "$port" -le 65535 ]] || fail "Invalid socket address (out of range): $addr"

  printf '%s\n%s\n' "$host" "$port"
}

run_mux_cmd() {
  local mux_socket="${1:-}"
  shift

  if [[ -n "$mux_socket" ]]; then
    USBMUXD_SOCKET_ADDRESS="$mux_socket" "$@"
  else
    "$@"
  fi
}

is_tcp_listening() {
  local host="$1"
  local port="$2"

  require_cmd python3
  python3 - "$host" "$port" <<'PY'
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(0.4)
try:
    s.connect((host, port))
    sys.exit(0)
except Exception:
    sys.exit(1)
finally:
    s.close()
PY
}

netmuxd_asset_name() {
  case "$(uname -m)" in
    x86_64|amd64)
      printf 'netmuxd-x86_64-linux-gnu'
      ;;
    aarch64|arm64)
      printf 'netmuxd-aarch64-linux-gnu'
      ;;
    *)
      fail "Unsupported architecture for netmuxd prebuilt install: $(uname -m)"
      ;;
  esac
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

ensure_submodules() {
  local required_paths=(
    "$REPO_ROOT/upstream_repo/ldid/ldid.cpp"
    "$REPO_ROOT/libraries/libplist/libcnary/node.c"
  )
  local missing=0
  local p

  for p in "${required_paths[@]}"; do
    if [[ ! -f "$p" ]]; then
      missing=1
      break
    fi
  done

  if [[ "$missing" -eq 0 ]]; then
    return 0
  fi

  require_cmd git
  [[ -d "$REPO_ROOT/.git" ]] || fail "Submodules are missing and this is not a git checkout"

  info "Initializing/updating git submodules recursively"
  git -C "$REPO_ROOT" submodule update --init --recursive
}

sudo_run() {
  if [[ "$EUID" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

enable_or_start_service() {
  local service="$1"
  local unit_state

  unit_state="$(systemctl show -p UnitFileState --value "$service" 2>/dev/null || echo unknown)"

  case "$unit_state" in
    static|indirect|generated|transient)
      warn "Service $service has UnitFileState=$unit_state; starting without enable"
      sudo_run systemctl start "$service"
      ;;
    masked)
      fail "Service $service is masked"
      ;;
    *)
      sudo_run systemctl enable --now "$service"
      ;;
  esac
}

ensure_build_dir_writable() {
  mkdir -p "$BUILD_DIR"

  if find "$BUILD_DIR" -mindepth 1 ! -user "$(id -un)" -print -quit | grep -q .; then
    warn "Build directory contains files not owned by $(id -un): $BUILD_DIR"
    warn "Trying to fix ownership via sudo chown"
    sudo_run chown -R "$(id -u):$(id -g)" "$BUILD_DIR"
  fi

  if touch "$BUILD_DIR/.write-test" 2>/dev/null; then
    rm -f "$BUILD_DIR/.write-test"
    return 0
  fi

  warn "Build directory is not writable: $BUILD_DIR"
  warn "Trying to fix ownership via sudo chown"
  sudo_run chown -R "$(id -u):$(id -g)" "$BUILD_DIR"

  touch "$BUILD_DIR/.write-test" 2>/dev/null || fail "Build directory remains non-writable: $BUILD_DIR"
  rm -f "$BUILD_DIR/.write-test"
}

arch_to_asset() {
  case "$(uname -m)" in
    x86_64|amd64)
      printf 'AltServer-x86_64'
      ;;
    aarch64|arm64)
      printf 'AltServer-aarch64'
      ;;
    armv7l)
      printf 'AltServer-arm'
      ;;
    i386|i686)
      printf 'AltServer-i386'
      ;;
    *)
      printf 'AltServer-x86_64'
      ;;
  esac
}

find_altserver_binary() {
  local explicit="${1:-}"
  local asset
  local candidate

  if [[ -n "$explicit" ]]; then
    [[ -x "$explicit" ]] || fail "AltServer binary is not executable: $explicit"
    printf '%s\n' "$explicit"
    return 0
  fi

  asset="$(arch_to_asset)"
  candidate="$BUILD_DIR/$asset"
  if [[ -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  candidate="$(find "$BUILD_DIR" -maxdepth 1 -type f -name 'AltServer-*' | head -n1 || true)"
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  if [[ -x "$DEFAULT_INSTALL_PATH" ]]; then
    printf '%s\n' "$DEFAULT_INSTALL_PATH"
    return 0
  fi

  fail "AltServer binary not found. Run '$SCRIPT_NAME build --install' first."
}

find_built_artifact() {
  local asset
  local candidate

  asset="$(arch_to_asset)"
  candidate="$BUILD_DIR/$asset"
  if [[ -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  candidate="$(find "$BUILD_DIR" -maxdepth 1 -type f -name 'AltServer-*' | head -n1 || true)"
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  fail "No built AltServer artifact found under $BUILD_DIR"
}

install_binary() {
  local src="$1"
  local dst="${2:-$DEFAULT_INSTALL_PATH}"
  local parent_dir

  [[ -x "$src" ]] || fail "Binary is not executable: $src"
  parent_dir="$(dirname "$dst")"
  [[ -d "$parent_dir" ]] || fail "Destination directory does not exist: $parent_dir"

  info "Installing $src -> $dst"
  if [[ -w "$parent_dir" ]]; then
    install -m 0755 "$src" "$dst"
  else
    sudo_run install -m 0755 "$src" "$dst"
  fi
}

download_release_binary() {
  local asset
  local url

  require_cmd curl

  asset="$(arch_to_asset)"
  url="https://github.com/NyaMisty/AltServer-Linux/releases/download/v0.0.5/${asset}"

  ensure_build_dir_writable
  printf '[INFO] Downloading precompiled release: %s\n' "$url" >&2
  rm -f "$BUILD_DIR/$asset"
  curl -fL "$url" -o "$BUILD_DIR/$asset" || fail "Failed to download release binary"
  chmod +x "$BUILD_DIR/$asset" || fail "Failed to chmod release binary"

  printf '%s\n' "$BUILD_DIR/$asset"
}

build_altserver() {
  local mode="docker"
  local force_local_image="false"
  local install_after="false"
  local install_path="$DEFAULT_INSTALL_PATH"
  local artifact=""
  local image="$DEFAULT_BUILDER_IMAGE"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --release)
        mode="release"
        ;;
      --force-local-image)
        force_local_image="true"
        ;;
      --install)
        install_after="true"
        ;;
      --install-path)
        shift
        [[ $# -gt 0 ]] || fail "Missing value for --install-path"
        install_path="$1"
        ;;
      *)
        fail "Unknown build option: $1"
        ;;
    esac
    shift
  done

  if [[ "$mode" == "release" ]]; then
    artifact="$(download_release_binary)" || fail "Release binary download failed"
  else
    require_cmd docker

    ensure_submodules
    ensure_build_dir_writable

    if [[ "$force_local_image" == "false" ]]; then
      info "Pulling builder image: $image"
      if ! docker pull "$image" >/dev/null; then
        warn "Could not pull $image, falling back to local Docker build"
        force_local_image="true"
      fi
    fi

    if [[ "$force_local_image" == "true" ]]; then
      image="$DEFAULT_LOCAL_BUILDER_IMAGE"
      info "Building local builder image from buildenv/Dockerfile"
      docker build -t "$image" "$REPO_ROOT/buildenv"
    fi

    rm -f "$BUILD_DIR"/AltServer-*
    info "Building AltServer inside container"
    docker run --rm -u "$(id -u):$(id -g)" -v "$REPO_ROOT:/workdir" -w /workdir "$image" \
      sh -lc 'mkdir -p build && cd build && make -f ../Makefile -j"$(nproc)"'

    artifact="$(find_built_artifact)"
  fi

  info "Built binary: $artifact"

  if [[ "$install_after" == "true" ]]; then
    install_binary "$artifact" "$install_path"
  fi
}

install_deps() {
  local install_docker="true"
  local with_netmuxd="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-docker)
        install_docker="false"
        ;;
      --with-netmuxd)
        with_netmuxd="true"
        ;;
      *)
        fail "Unknown install-deps option: $1"
        ;;
    esac
    shift
  done

  require_cmd pacman

  local pkgs=(usbmuxd python avahi nss-mdns libimobiledevice curl jq)
  if [[ "$install_docker" == "true" ]]; then
    pkgs+=(docker)
  fi

  info "Installing runtime dependencies via pacman"
  sudo_run pacman -S --needed "${pkgs[@]}"

  info "Enabling required services"
  enable_or_start_service usbmuxd.service
  enable_or_start_service avahi-daemon.service

  if [[ "$install_docker" == "true" ]]; then
    enable_or_start_service docker.service
  fi

  if getent group usbmuxd >/dev/null 2>&1; then
    if id -nG "$USER" | grep -qw usbmuxd; then
      info "User already in usbmuxd group"
    else
      warn "Adding $USER to usbmuxd group"
      sudo_run usermod -aG usbmuxd "$USER"
      warn "Re-login is required for usbmuxd group membership"
    fi
  else
    info "Group usbmuxd is absent on this system; skipping group assignment"
  fi

  if [[ "$install_docker" == "true" ]]; then
    if getent group docker >/dev/null 2>&1; then
      if id -nG "$USER" | grep -qw docker; then
        info "User already in docker group"
      else
        warn "Adding $USER to docker group"
        sudo_run usermod -aG docker "$USER"
        warn "Re-login is required for docker group membership"
      fi
    else
      warn "Group docker is absent; docker commands may require sudo"
    fi
  fi

  if [[ "$with_netmuxd" == "true" ]]; then
    install_netmuxd
  fi
}

install_netmuxd() {
  local version="latest"
  local bin_path="$DEFAULT_NETMUXD_BIN"
  local repo="jkcoxson/netmuxd"
  local force="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        shift
        [[ $# -gt 0 ]] || fail "Missing value for --version"
        version="$1"
        ;;
      --bin-path)
        shift
        [[ $# -gt 0 ]] || fail "Missing value for --bin-path"
        bin_path="$1"
        ;;
      --repo)
        shift
        [[ $# -gt 0 ]] || fail "Missing value for --repo"
        repo="$1"
        ;;
      --force)
        force="true"
        ;;
      *)
        fail "Unknown install-netmuxd option: $1"
        ;;
    esac
    shift
  done

  require_cmd curl
  require_cmd jq

  local api_url
  if [[ "$version" == "latest" ]]; then
    api_url="https://api.github.com/repos/${repo}/releases/latest"
  else
    api_url="https://api.github.com/repos/${repo}/releases/tags/${version}"
  fi

  local response
  response="$(curl -fsSL "$api_url")" || fail "Failed to fetch netmuxd release metadata: $api_url"

  local tag
  tag="$(jq -r '.tag_name // empty' <<<"$response")"
  [[ -n "$tag" ]] || fail "Could not read netmuxd release tag from GitHub API response"

  local asset
  asset="$(netmuxd_asset_name)"

  local url
  url="$(jq -r --arg name "$asset" '.assets[] | select(.name == $name) | .browser_download_url' <<<"$response" | head -n1)"
  [[ -n "$url" && "$url" != "null" ]] || fail "Could not find release asset '${asset}' in ${tag}"

  if [[ -x "$bin_path" && "$force" != "true" ]]; then
    info "netmuxd already exists: $bin_path (use --force to overwrite)"
    return 0
  fi

  local tmp
  tmp="$(mktemp)"

  info "Downloading netmuxd ${tag} (${asset})"
  curl -fL "$url" -o "$tmp" || fail "Failed to download netmuxd binary"
  chmod +x "$tmp"

  local parent_dir
  parent_dir="$(dirname "$bin_path")"
  [[ -d "$parent_dir" ]] || fail "Directory does not exist: $parent_dir"

  info "Installing netmuxd -> $bin_path"
  if [[ -w "$parent_dir" ]]; then
    install -m 0755 "$tmp" "$bin_path"
  else
    sudo_run install -m 0755 "$tmp" "$bin_path"
  fi

  rm -f "$tmp"
  info "Installed netmuxd successfully"
}

netmuxd_check() {
  local bin_path="$DEFAULT_NETMUXD_BIN"
  local mux_socket=""
  local expect_running="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --bin-path)
        shift
        [[ $# -gt 0 ]] || fail "Missing value for --bin-path"
        bin_path="$1"
        ;;
      --mux-socket)
        shift
        [[ $# -gt 0 ]] || fail "Missing value for --mux-socket"
        mux_socket="$1"
        ;;
      --expect-running)
        expect_running="true"
        ;;
      *)
        fail "Unknown netmuxd-check option: $1"
        ;;
    esac
    shift
  done

  if [[ -z "$mux_socket" ]]; then
    mux_socket="$(default_mux_socket)"
  fi

  if [[ -x "$bin_path" ]]; then
    printf '[ OK ] netmuxd binary: %s\n' "$bin_path"
  else
    printf '[WARN] netmuxd binary missing: %s\n' "$bin_path"
    [[ "$expect_running" != "true" ]] || return 1
  fi

  local host
  local port
  mapfile -t _sock_parts < <(split_socket_address "$mux_socket")
  host="${_sock_parts[0]}"
  port="${_sock_parts[1]}"

  if is_tcp_listening "$host" "$port"; then
    printf '[ OK ] netmuxd socket reachable: %s\n' "$mux_socket"
  else
    printf '[WARN] netmuxd socket not reachable: %s\n' "$mux_socket"
    [[ "$expect_running" != "true" ]] || return 1
  fi

  if command -v idevice_id >/dev/null 2>&1; then
    local count
    count="$({ run_mux_cmd "$mux_socket" idevice_id -n 2>/dev/null || true; } | wc -l | tr -d ' ')"
    printf '[INFO] devices via %s: %s\n' "$mux_socket" "$count"
  fi
}

netmuxd_up() {
  local bin_path="$DEFAULT_NETMUXD_BIN"
  local mux_socket=""
  local stop_usbmuxd="false"
  local pidfile="$DEFAULT_NETMUXD_PIDFILE"
  local logfile="$DEFAULT_NETMUXD_LOGFILE"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --bin-path)
        shift
        [[ $# -gt 0 ]] || fail "Missing value for --bin-path"
        bin_path="$1"
        ;;
      --mux-socket)
        shift
        [[ $# -gt 0 ]] || fail "Missing value for --mux-socket"
        mux_socket="$1"
        ;;
      --pidfile)
        shift
        [[ $# -gt 0 ]] || fail "Missing value for --pidfile"
        pidfile="$1"
        ;;
      --logfile)
        shift
        [[ $# -gt 0 ]] || fail "Missing value for --logfile"
        logfile="$1"
        ;;
      --stop-usbmuxd)
        stop_usbmuxd="true"
        ;;
      *)
        fail "Unknown netmuxd-up option: $1"
        ;;
    esac
    shift
  done

  [[ -x "$bin_path" ]] || fail "netmuxd binary is not executable: $bin_path"
  if [[ -z "$mux_socket" ]]; then
    mux_socket="$(default_mux_socket)"
  fi

  local host
  local port
  mapfile -t _sock_parts < <(split_socket_address "$mux_socket")
  host="${_sock_parts[0]}"
  port="${_sock_parts[1]}"

  if is_tcp_listening "$host" "$port"; then
    info "netmuxd socket already reachable: $mux_socket"
    printf '[INFO] Export for this shell: export USBMUXD_SOCKET_ADDRESS=%s\n' "$mux_socket"
    return 0
  fi

  if [[ "$stop_usbmuxd" == "true" ]] && command -v systemctl >/dev/null 2>&1; then
    info "Stopping usbmuxd service as requested"
    sudo_run systemctl stop usbmuxd.service || true
  fi

  info "Starting netmuxd in extension mode on $mux_socket"
  nohup "$bin_path" --disable-unix --host "$host" --port "$port" >"$logfile" 2>&1 &
  local pid=$!
  printf '%s\n' "$pid" > "$pidfile"

  local ok="false"
  for _ in $(seq 1 25); do
    if is_tcp_listening "$host" "$port"; then
      ok="true"
      break
    fi
    sleep 0.2
  done

  [[ "$ok" == "true" ]] || fail "netmuxd did not become reachable on $mux_socket (log: $logfile)"
  info "netmuxd is running (pid=$pid, log=$logfile)"
  printf '[INFO] Export for this shell: export USBMUXD_SOCKET_ADDRESS=%s\n' "$mux_socket"
}

netmuxd_down() {
  local pidfile="$DEFAULT_NETMUXD_PIDFILE"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pidfile)
        shift
        [[ $# -gt 0 ]] || fail "Missing value for --pidfile"
        pidfile="$1"
        ;;
      *)
        fail "Unknown netmuxd-down option: $1"
        ;;
    esac
    shift
  done

  if [[ ! -f "$pidfile" ]]; then
    warn "PID file not found: $pidfile"
    return 0
  fi

  local pid
  pid="$(cat "$pidfile" 2>/dev/null || true)"
  [[ -n "$pid" ]] || fail "PID file is empty: $pidfile"

  if kill -0 "$pid" 2>/dev/null; then
    info "Stopping netmuxd pid=$pid"
    kill "$pid" || true
  else
    warn "Process from PID file is not running: $pid"
  fi

  rm -f "$pidfile"
}

anisette_check() {
  local url="${1:-http://127.0.0.1:${DEFAULT_ANISETTE_PORT}}"
  local payload

  require_cmd curl
  require_cmd python3

  info "Checking anisette endpoint: $url"
  payload="$(curl -fsS "$url")"
  python3 - "$payload" "${ANIS_KEYS[@]}" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
keys = sys.argv[2:]
missing = [k for k in keys if k not in payload]
if missing:
    print("Missing keys:", ", ".join(missing), file=sys.stderr)
    sys.exit(1)
print("Anisette JSON looks valid")
PY
}

anisette_up() {
  local port="$DEFAULT_ANISETTE_PORT"
  local image="$DEFAULT_ANISETTE_IMAGE"
  local container="$DEFAULT_ANISETTE_CONTAINER"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port)
        shift
        [[ $# -gt 0 ]] || fail "Missing value for --port"
        port="$1"
        ;;
      --image)
        shift
        [[ $# -gt 0 ]] || fail "Missing value for --image"
        image="$1"
        ;;
      --container)
        shift
        [[ $# -gt 0 ]] || fail "Missing value for --container"
        container="$1"
        ;;
      *)
        fail "Unknown anisette-up option: $1"
        ;;
    esac
    shift
  done

  require_cmd docker

  if docker ps -a --format '{{.Names}}' | grep -qx "$container"; then
    info "Removing existing anisette container: $container"
    docker rm -f "$container" >/dev/null
  fi

  info "Starting anisette container $container on port $port"
  docker run -d --name "$container" --restart unless-stopped -p "${port}:6969" "$image" >/dev/null

  local url="http://127.0.0.1:${port}"
  local ok="false"
  for _ in $(seq 1 30); do
    if anisette_check "$url" >/dev/null 2>&1; then
      ok="true"
      break
    fi
    sleep 1
  done

  [[ "$ok" == "true" ]] || fail "Anisette container started but health check failed: $url"
  info "Anisette server is healthy: $url"
}

anisette_down() {
  local container="$DEFAULT_ANISETTE_CONTAINER"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --container)
        shift
        [[ $# -gt 0 ]] || fail "Missing value for --container"
        container="$1"
        ;;
      *)
        fail "Unknown anisette-down option: $1"
        ;;
    esac
    shift
  done

  require_cmd docker

  if docker ps -a --format '{{.Names}}' | grep -qx "$container"; then
    info "Stopping anisette container: $container"
    docker rm -f "$container" >/dev/null
  else
    info "Container not found: $container"
  fi
}

download_altstore() {
  local output="$DEFAULT_ALTSTORE_OUTPUT"
  local source_url="$DEFAULT_ALTSTORE_SOURCE_URL"
  local bundle_id="$DEFAULT_ALTSTORE_BUNDLE_ID"
  local direct_url=""
  local release_tag="direct"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out)
        shift
        [[ $# -gt 0 ]] || fail "Missing value for --out"
        output="$1"
        ;;
      --source-url)
        shift
        [[ $# -gt 0 ]] || fail "Missing value for --source-url"
        source_url="$1"
        ;;
      --bundle-id)
        shift
        [[ $# -gt 0 ]] || fail "Missing value for --bundle-id"
        bundle_id="$1"
        ;;
      --url)
        shift
        [[ $# -gt 0 ]] || fail "Missing value for --url"
        direct_url="$1"
        ;;
      *)
        fail "Unknown download-altstore option: $1"
        ;;
    esac
    shift
  done

  require_cmd curl
  require_cmd jq

  local url="$direct_url"
  if [[ -z "$url" ]]; then
    local response
    response="$(curl -fsSL "$source_url")" || fail "Failed to fetch AltStore source metadata: $source_url"

    release_tag="$(jq -r --arg bid "$bundle_id" '.apps[] | select(.bundleIdentifier==$bid) | .versions[0].version // empty' <<<"$response" | head -n1)"
    url="$(jq -r --arg bid "$bundle_id" '.apps[] | select(.bundleIdentifier==$bid) | .versions[0].downloadURL // empty' <<<"$response" | head -n1)"
    [[ -n "$release_tag" ]] || release_tag="unknown"
    [[ -n "$url" ]] || fail "Could not find download URL for bundle '${bundle_id}' in source: $source_url"
  fi

  local output_dir
  output_dir="$(dirname "$output")"
  mkdir -p "$output_dir"

  local tmp
  tmp="$(mktemp)"
  info "Downloading AltStore (${release_tag})"
  curl -fL "$url" -o "$tmp" || fail "Failed to download AltStore IPA from: $url"
  mv "$tmp" "$output"
  info "Saved AltStore IPA to: $output"
}

list_devices() {
  local mux_socket=""
  local prefer_netmuxd="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mux-socket)
        shift
        [[ $# -gt 0 ]] || fail "Missing value for --mux-socket"
        mux_socket="$1"
        ;;
      --prefer-netmuxd)
        prefer_netmuxd="true"
        ;;
      *)
        fail "Unknown list-devices option: $1"
        ;;
    esac
    shift
  done

  if [[ "$prefer_netmuxd" == "true" && -z "$mux_socket" ]]; then
    mux_socket="$(default_mux_socket)"
  fi

  require_cmd idevice_id
  require_cmd ideviceinfo

  local idevice_id_mode=(-l)
  local ideviceinfo_mode=()
  if [[ "$prefer_netmuxd" == "true" ]] || ([[ -n "$mux_socket" ]] && [[ "$mux_socket" != UNIX:* ]]); then
    idevice_id_mode=(-n)
    ideviceinfo_mode=(-n)
  fi

  local udids
  mapfile -t udids < <(run_mux_cmd "$mux_socket" idevice_id "${idevice_id_mode[@]}" 2>/dev/null || true)

  if [[ "${#udids[@]}" -eq 0 ]]; then
    if [[ -n "$mux_socket" ]]; then
      warn "No iOS devices detected via USBMUXD_SOCKET_ADDRESS=$mux_socket"
    else
      warn "No iOS devices detected"
    fi
    return 1
  fi

  if [[ -n "$mux_socket" ]]; then
    info "Detected iOS devices via USBMUXD_SOCKET_ADDRESS=$mux_socket:"
  else
    info "Detected iOS devices:"
  fi
  local udid
  for udid in "${udids[@]}"; do
    local name
    local version
    name="$(run_mux_cmd "$mux_socket" ideviceinfo "${ideviceinfo_mode[@]}" -u "$udid" -k DeviceName 2>/dev/null || echo unknown)"
    version="$(run_mux_cmd "$mux_socket" ideviceinfo "${ideviceinfo_mode[@]}" -u "$udid" -k ProductVersion 2>/dev/null || echo unknown)"
    printf '  - %s (%s, iOS %s)\n' "$udid" "$name" "$version"
  done
}

doctor() {
  local mux_socket=""
  local prefer_netmuxd="false"
  local failures=0
  local missing=()
  local cmds=(docker python3 idevice_id ideviceinfo avahi-browse curl systemctl)

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mux-socket)
        shift
        [[ $# -gt 0 ]] || fail "Missing value for --mux-socket"
        mux_socket="$1"
        ;;
      --prefer-netmuxd)
        prefer_netmuxd="true"
        ;;
      *)
        fail "Unknown doctor option: $1"
        ;;
    esac
    shift
  done

  if [[ "$prefer_netmuxd" == "true" && -z "$mux_socket" ]]; then
    mux_socket="$(default_mux_socket)"
  fi

  info "Running environment checks"

  local c
  for c in "${cmds[@]}"; do
    if command -v "$c" >/dev/null 2>&1; then
      printf '[ OK ] command: %s\n' "$c"
    else
      printf '[FAIL] command missing: %s\n' "$c"
      missing+=("$c")
      failures=$((failures + 1))
    fi
  done

  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet usbmuxd; then
      printf '[ OK ] service active: usbmuxd\n'
    else
      printf '[WARN] service inactive: usbmuxd\n'
    fi

    if systemctl is-active --quiet avahi-daemon; then
      printf '[ OK ] service active: avahi-daemon\n'
    else
      printf '[WARN] service inactive: avahi-daemon\n'
    fi
  fi

  if command -v docker >/dev/null 2>&1; then
    if docker info >/dev/null 2>&1; then
      printf '[ OK ] docker daemon reachable\n'
    else
      printf '[WARN] docker daemon unreachable (start service or fix group membership)\n'
    fi
  fi

  if command -v idevice_id >/dev/null 2>&1; then
    local count
    local idevice_id_mode=(-l)
    if [[ "$prefer_netmuxd" == "true" ]] || ([[ -n "$mux_socket" ]] && [[ "$mux_socket" != UNIX:* ]]); then
      idevice_id_mode=(-n)
    fi

    count="$({ run_mux_cmd "$mux_socket" idevice_id "${idevice_id_mode[@]}" 2>/dev/null || true; } | wc -l | tr -d ' ')"
    if [[ "$count" -gt 0 ]]; then
      if [[ -n "$mux_socket" ]]; then
        printf '[ OK ] iOS devices detected via %s: %s\n' "$mux_socket" "$count"
      else
        printf '[ OK ] iOS devices detected: %s\n' "$count"
      fi
    else
      if [[ -n "$mux_socket" ]]; then
        printf '[WARN] iOS devices detected via %s: 0\n' "$mux_socket"
      else
        printf '[WARN] iOS devices detected: 0\n'
      fi
    fi
  fi

  if [[ "$prefer_netmuxd" == "true" ]] || command -v netmuxd >/dev/null 2>&1 || [[ -x "$DEFAULT_NETMUXD_BIN" ]]; then
    netmuxd_check --bin-path "$DEFAULT_NETMUXD_BIN" --mux-socket "$(default_mux_socket)" || true
  fi

  if [[ "$failures" -gt 0 ]]; then
    fail "Doctor failed. Missing commands: ${missing[*]}"
  fi

  info "Doctor completed"
}

run_daemon() {
  local altserver=""
  local anisette_url="${ALTSERVER_ANISETTE_SERVER:-http://127.0.0.1:${DEFAULT_ANISETTE_PORT}}"
  local debug_level=0
  local mux_socket=""
  local prefer_netmuxd="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --altserver)
        shift
        [[ $# -gt 0 ]] || fail "Missing value for --altserver"
        altserver="$1"
        ;;
      --anisette)
        shift
        [[ $# -gt 0 ]] || fail "Missing value for --anisette"
        anisette_url="$1"
        ;;
      --debug-level)
        shift
        [[ $# -gt 0 ]] || fail "Missing value for --debug-level"
        debug_level="$1"
        ;;
      --mux-socket)
        shift
        [[ $# -gt 0 ]] || fail "Missing value for --mux-socket"
        mux_socket="$1"
        ;;
      --prefer-netmuxd)
        prefer_netmuxd="true"
        ;;
      *)
        fail "Unknown daemon option: $1"
        ;;
    esac
    shift
  done

  local bin
  bin="$(find_altserver_binary "$altserver")"

  if [[ "$prefer_netmuxd" == "true" && -z "$mux_socket" ]]; then
    mux_socket="$(default_mux_socket)"
  fi

  require_cmd python3
  anisette_check "$anisette_url"

  local debug_flags=()
  local i
  for ((i=0; i<debug_level; i++)); do
    debug_flags+=("-d")
  done

  info "Starting AltServer daemon"
  info "AltServer binary: $bin"
  info "ALTSERVER_ANISETTE_SERVER=$anisette_url"
  if [[ -n "$mux_socket" ]]; then
    info "USBMUXD_SOCKET_ADDRESS=$mux_socket"
    ALTSERVER_ANISETTE_SERVER="$anisette_url" USBMUXD_SOCKET_ADDRESS="$mux_socket" exec "$bin" "${debug_flags[@]}"
  else
    ALTSERVER_ANISETTE_SERVER="$anisette_url" exec "$bin" "${debug_flags[@]}"
  fi
}

run_install() {
  local altserver=""
  local anisette_url="${ALTSERVER_ANISETTE_SERVER:-http://127.0.0.1:${DEFAULT_ANISETTE_PORT}}"
  local udid=""
  local apple_id=""
  local password=""
  local ipa="$DEFAULT_ALTSTORE_OUTPUT"
  local debug_level=0
  local mux_socket=""
  local prefer_netmuxd="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --altserver)
        shift
        [[ $# -gt 0 ]] || fail "Missing value for --altserver"
        altserver="$1"
        ;;
      --anisette)
        shift
        [[ $# -gt 0 ]] || fail "Missing value for --anisette"
        anisette_url="$1"
        ;;
      -u|--udid)
        shift
        [[ $# -gt 0 ]] || fail "Missing value for --udid"
        udid="$1"
        ;;
      -a|--apple-id)
        shift
        [[ $# -gt 0 ]] || fail "Missing value for --apple-id"
        apple_id="$1"
        ;;
      -p|--password)
        shift
        [[ $# -gt 0 ]] || fail "Missing value for --password"
        password="$1"
        ;;
      -i|--ipa)
        shift
        [[ $# -gt 0 ]] || fail "Missing value for --ipa"
        ipa="$1"
        ;;
      --debug-level)
        shift
        [[ $# -gt 0 ]] || fail "Missing value for --debug-level"
        debug_level="$1"
        ;;
      --mux-socket)
        shift
        [[ $# -gt 0 ]] || fail "Missing value for --mux-socket"
        mux_socket="$1"
        ;;
      --prefer-netmuxd)
        prefer_netmuxd="true"
        ;;
      *)
        fail "Unknown install option: $1"
        ;;
    esac
    shift
  done

  [[ -n "$udid" ]] || fail "--udid is required"
  [[ -n "$apple_id" ]] || fail "--apple-id is required"
  [[ -n "$password" ]] || fail "--password is required ('-' to prompt securely)"
  [[ -f "$ipa" ]] || fail "IPA file not found: $ipa (use '$SCRIPT_NAME download-altstore' or pass --ipa FILE)"

  if [[ "$password" == "-" ]]; then
    read -rsp 'Apple ID password: ' password
    printf '\n'
  fi

  local bin
  bin="$(find_altserver_binary "$altserver")"

  if [[ "$prefer_netmuxd" == "true" && -z "$mux_socket" ]]; then
    mux_socket="$(default_mux_socket)"
  fi

  anisette_check "$anisette_url"

  local debug_flags=()
  local i
  for ((i=0; i<debug_level; i++)); do
    debug_flags+=("-d")
  done

  info "Installing IPA with AltServer"
  info "AltServer binary: $bin"
  info "Device UDID: $udid"
  if [[ -n "$mux_socket" ]]; then
    info "USBMUXD_SOCKET_ADDRESS=$mux_socket"
    ALTSERVER_ANISETTE_SERVER="$anisette_url" USBMUXD_SOCKET_ADDRESS="$mux_socket" "$bin" "${debug_flags[@]}" -u "$udid" -a "$apple_id" -p "$password" "$ipa"
  else
    ALTSERVER_ANISETTE_SERVER="$anisette_url" "$bin" "${debug_flags[@]}" -u "$udid" -a "$apple_id" -p "$password" "$ipa"
  fi
}

bootstrap() {
  local skip_deps="false"
  local skip_build="false"
  local skip_anisette="false"
  local skip_altstore="false"
  local use_release="false"
  local with_netmuxd="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skip-deps)
        skip_deps="true"
        ;;
      --skip-build)
        skip_build="true"
        ;;
      --skip-anisette)
        skip_anisette="true"
        ;;
      --skip-altstore)
        skip_altstore="true"
        ;;
      --release)
        use_release="true"
        ;;
      --with-netmuxd)
        with_netmuxd="true"
        ;;
      *)
        fail "Unknown bootstrap option: $1"
        ;;
    esac
    shift
  done

  if [[ "$skip_deps" == "false" ]]; then
    if [[ "$with_netmuxd" == "true" ]]; then
      install_deps --with-netmuxd
    else
      install_deps
    fi
  fi

  if [[ "$skip_build" == "false" ]]; then
    if [[ "$use_release" == "true" ]]; then
      build_altserver --release --install
    else
      build_altserver --install
    fi
  fi

  if [[ "$skip_anisette" == "false" ]]; then
    anisette_up
  fi

  if [[ "$skip_altstore" == "false" ]]; then
    download_altstore
  fi

  if [[ "$with_netmuxd" == "true" ]]; then
    netmuxd_up
  fi

  if [[ "$with_netmuxd" == "true" ]]; then
    doctor --prefer-netmuxd
  else
    doctor
  fi

  cat <<MSG

Bootstrap completed.

Next steps:
1. Plug iPhone via USB and tap Trust.
2. Run: $SCRIPT_NAME list-devices
3. Run daemon mode for refresh:
   $SCRIPT_NAME daemon --debug-level 2
4. In AltStore on iPhone: Settings -> Refresh All.

For Wi-Fi refresh on newer iOS:
  $SCRIPT_NAME netmuxd-check
  $SCRIPT_NAME daemon --debug-level 2 --prefer-netmuxd

MSG
}

usage() {
  cat <<'USAGE'
AltServer-Linux helper for Arch Linux.

Usage:
  scripts/altstore-linux.sh <command> [options]

Commands:
  doctor [--mux-socket HOST:PORT] [--prefer-netmuxd]
    Validate command availability, services, docker access, and device visibility.

  install-deps [--no-docker] [--with-netmuxd]
    Install runtime packages on Arch and enable usbmuxd/avahi (+docker by default).

  build [--install] [--install-path PATH] [--release] [--force-local-image]
    Build AltServer via docker builder image or download release binary.

  install-netmuxd [--version latest|TAG] [--bin-path PATH] [--repo OWNER/REPO] [--force]
    Download netmuxd binary from GitHub releases and install it locally.

  netmuxd-up [--bin-path PATH] [--mux-socket HOST:PORT] [--stop-usbmuxd]
    Start netmuxd extension socket (recommended for Wi-Fi refresh).

  netmuxd-down [--pidfile FILE]
    Stop netmuxd started by netmuxd-up.

  netmuxd-check [--bin-path PATH] [--mux-socket HOST:PORT]
    Check netmuxd binary/socket and print discovered device count via netmuxd.

  anisette-up [--port PORT] [--image IMAGE] [--container NAME]
    Start local anisette server in Docker and wait for healthy JSON response.

  anisette-down [--container NAME]
    Stop/remove anisette container.

  anisette-check [--url URL]
    Validate anisette response schema.

  download-altstore [--out FILE] [--source-url URL] [--bundle-id ID] [--url URL]
    Download latest AltStore IPA (default: ./AltStore.ipa in repo root).

  list-devices [--mux-socket HOST:PORT] [--prefer-netmuxd]
    List connected iOS devices (UDID, name, iOS version).

  daemon [--altserver PATH] [--anisette URL] [--debug-level N] [--mux-socket HOST:PORT] [--prefer-netmuxd]
    Run AltServer in daemon mode (used by AltStore refresh).

  install --udid UDID --apple-id APPLE_ID --password PASSWORD [--ipa FILE] [--altserver PATH] [--anisette URL] [--debug-level N] [--mux-socket HOST:PORT] [--prefer-netmuxd]
    Install/sign IPA directly with AltServer install mode (default IPA: ./AltStore.ipa).

  bootstrap [--skip-deps] [--skip-build] [--skip-anisette] [--skip-altstore] [--release] [--with-netmuxd]
    End-to-end setup workflow for a fresh Arch Linux machine.
USAGE
}

main() {
  local cmd="${1:-}"
  if [[ -z "$cmd" ]]; then
    usage
    exit 1
  fi
  shift

  case "$cmd" in
    doctor)
      doctor "$@"
      ;;
    install-deps)
      install_deps "$@"
      ;;
    build)
      build_altserver "$@"
      ;;
    install-netmuxd)
      install_netmuxd "$@"
      ;;
    netmuxd-up)
      netmuxd_up "$@"
      ;;
    netmuxd-down)
      netmuxd_down "$@"
      ;;
    netmuxd-check)
      netmuxd_check "$@"
      ;;
    anisette-up)
      anisette_up "$@"
      ;;
    anisette-down)
      anisette_down "$@"
      ;;
    anisette-check)
      local url="http://127.0.0.1:${DEFAULT_ANISETTE_PORT}"
      if [[ "${1:-}" == "--url" ]]; then
        shift
        [[ $# -gt 0 ]] || fail "Missing value for --url"
        url="$1"
        shift
      fi
      [[ $# -eq 0 ]] || fail "Unknown anisette-check option: $*"
      anisette_check "$url"
      ;;
    download-altstore)
      download_altstore "$@"
      ;;
    list-devices)
      list_devices "$@"
      ;;
    daemon)
      run_daemon "$@"
      ;;
    install)
      run_install "$@"
      ;;
    bootstrap)
      bootstrap "$@"
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      fail "Unknown command: $cmd"
      ;;
  esac
}

main "$@"
