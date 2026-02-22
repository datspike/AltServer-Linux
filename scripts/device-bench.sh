#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/device-bench.sh afc [--udid UDID] [--runs N] [--size-mb N] [--mux-socket HOST:PORT]
  scripts/device-bench.sh daemon --altserver PATH [--seconds N] [--debug-level N] [--mux-socket HOST:PORT]
  scripts/device-bench.sh install-altstore --altserver PATH --udid UDID --apple-id ID --password PASS|-
                                     --ipa PATH [--debug-level N] [--mux-socket HOST:PORT]

Notes:
  - MB/s is computed as bytes / seconds / 1_000_000.
  - Use --password - for secure prompt.
  - iOS trust/developer dialogs are manual steps (human-in-the-loop).
EOF
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }
}

pick_udid() {
  local mux_socket="${1:-}"
  if [[ -n "$mux_socket" ]]; then
    USBMUXD_SOCKET_ADDRESS="$mux_socket" idevice_id -l | head -n1
  else
    idevice_id -l | head -n1
  fi
}

run_afc_bench() {
  need_cmd idevice_id
  need_cmd afcclient
  need_cmd awk
  need_cmd sort

  local udid="${1:-}"
  local runs="${2:-3}"
  local size_mb="${3:-130}"
  local mux_socket="${4:-}"

  if [[ -z "$udid" ]]; then
    udid="$(pick_udid "$mux_socket")"
  fi
  [[ -n "$udid" ]] || { echo "No device UDID found" >&2; exit 1; }

  local file="/tmp/altserver-afc-bench-${size_mb}mb.bin"
  dd if=/dev/zero of="$file" bs=1M count="$size_mb" status=none
  local bytes
  bytes="$(stat -c %s "$file")"

  local values=()
  local run_cmd
  run_cmd="printf 'mkdir PublicStaging\nput $file PublicStaging/bench.bin\nrm PublicStaging/bench.bin\nquit\n' | afcclient -u $udid >/tmp/altserver-afc-bench.log 2>&1"
  if [[ -n "$mux_socket" ]]; then
    run_cmd="printf 'mkdir PublicStaging\nput $file PublicStaging/bench.bin\nrm PublicStaging/bench.bin\nquit\n' | USBMUXD_SOCKET_ADDRESS=$mux_socket afcclient -u $udid >/tmp/altserver-afc-bench.log 2>&1"
  fi

  local i out sec mbps
  for ((i=1; i<=runs; i++)); do
    out="$({ /usr/bin/time -f '%e' bash -lc "$run_cmd"; } 2>&1)"
    sec="${out##*$'\n'}"
    mbps="$(awk -v b="$bytes" -v s="$sec" 'BEGIN{printf "%.3f", b/s/1000000}')"
    values+=("$mbps")
    echo "run=$i seconds=$sec mbps=$mbps"
  done

  printf '%s\n' "${values[@]}" | sort -n > /tmp/altserver-afc-values.txt
  local mid=$(( (runs + 1) / 2 ))
  local median p95
  median="$(sed -n "${mid}p" /tmp/altserver-afc-values.txt)"
  p95="$(tail -n1 /tmp/altserver-afc-values.txt)"
  echo "summary runs=${runs} median_mb_s=${median} p95_mb_s=${p95}"
}

run_daemon_smoke() {
  need_cmd timeout
  local altserver="$1"
  local seconds="$2"
  local debug_level="$3"
  local mux_socket="${4:-}"

  [[ -x "$altserver" ]] || { echo "AltServer binary not executable: $altserver" >&2; exit 1; }
  local log="/tmp/altserver-daemon-smoke.log"
  echo "log=$log"
  if [[ -n "$mux_socket" ]]; then
    USBMUXD_SOCKET_ADDRESS="$mux_socket" timeout "$seconds" "$altserver" -$(printf 'd%.0s' $(seq 1 "$debug_level")) >"$log" 2>&1 || true
  else
    timeout "$seconds" "$altserver" -$(printf 'd%.0s' $(seq 1 "$debug_level")) >"$log" 2>&1 || true
  fi
  rg -n "Detected device|Starting notification connection|\\[WRITE\\]|Device lookup" "$log" || true
}

run_altstore_install() {
  local altserver="$1"
  local udid="$2"
  local apple_id="$3"
  local password="$4"
  local ipa="$5"
  local debug_level="$6"
  local mux_socket="${7:-}"

  [[ -x "$altserver" ]] || { echo "AltServer binary not executable: $altserver" >&2; exit 1; }
  [[ -f "$ipa" ]] || { echo "IPA not found: $ipa" >&2; exit 1; }
  [[ -n "$udid" && -n "$apple_id" ]] || { echo "Missing required install args" >&2; exit 1; }

  if [[ "$password" == "-" ]]; then
    read -r -s -p "Apple password: " password
    echo
  fi

  local dflags=""
  if (( debug_level > 0 )); then
    dflags="-$(printf 'd%.0s' $(seq 1 "$debug_level"))"
  fi

  local start end elapsed
  start="$(date +%s.%N)"
  if [[ -n "$mux_socket" ]]; then
    USBMUXD_SOCKET_ADDRESS="$mux_socket" "$altserver" $dflags -u "$udid" -a "$apple_id" -p "$password" "$ipa"
  else
    "$altserver" $dflags -u "$udid" -a "$apple_id" -p "$password" "$ipa"
  fi
  end="$(date +%s.%N)"
  elapsed="$(awk -v s="$start" -v e="$end" 'BEGIN{printf "%.3f", e-s}')"
  echo "install_elapsed_seconds=$elapsed"
}

cmd="${1:-}"
shift || true

case "$cmd" in
  afc)
    udid=""
    runs=3
    size_mb=130
    mux_socket=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --udid) udid="${2:-}"; shift 2 ;;
        --runs) runs="${2:-}"; shift 2 ;;
        --size-mb) size_mb="${2:-}"; shift 2 ;;
        --mux-socket) mux_socket="${2:-}"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
      esac
    done
    run_afc_bench "$udid" "$runs" "$size_mb" "$mux_socket"
    ;;
  daemon)
    altserver=""
    seconds=10
    debug_level=1
    mux_socket=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --altserver) altserver="${2:-}"; shift 2 ;;
        --seconds) seconds="${2:-}"; shift 2 ;;
        --debug-level) debug_level="${2:-}"; shift 2 ;;
        --mux-socket) mux_socket="${2:-}"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
      esac
    done
    [[ -n "$altserver" ]] || { echo "--altserver is required" >&2; exit 1; }
    run_daemon_smoke "$altserver" "$seconds" "$debug_level" "$mux_socket"
    ;;
  install-altstore)
    altserver=""
    udid=""
    apple_id=""
    password=""
    ipa=""
    debug_level=1
    mux_socket=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --altserver) altserver="${2:-}"; shift 2 ;;
        --udid) udid="${2:-}"; shift 2 ;;
        --apple-id) apple_id="${2:-}"; shift 2 ;;
        --password) password="${2:-}"; shift 2 ;;
        --ipa) ipa="${2:-}"; shift 2 ;;
        --debug-level) debug_level="${2:-}"; shift 2 ;;
        --mux-socket) mux_socket="${2:-}"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
      esac
    done
    [[ -n "$altserver" && -n "$udid" && -n "$apple_id" && -n "$password" && -n "$ipa" ]] || {
      echo "Missing required install-altstore arguments" >&2
      usage
      exit 1
    }
    run_altstore_install "$altserver" "$udid" "$apple_id" "$password" "$ipa" "$debug_level" "$mux_socket"
    ;;
  *)
    usage
    exit 1
    ;;
esac
