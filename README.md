# AltServer-Linux (updated-libs fork)

Linux port of AltServer with an updated dependency stack and USB/Wi-Fi install-path fixes.

Base reference: `NyaMisty/AltServer-Linux` branch `new` (`78764512`).

## What changed vs `NyaMisty/new`

- Dependency refresh to current stable tags (`libplist`, `libusbmuxd`, `libimobiledevice`, `ideviceinstaller`, `libimobiledevice-glue`) and an updated `upstream_repo` develop snapshot (`2ef20b38db9c`).
- Additional runtime fixes applied on top of latest upstream:
  - USB-first with automatic netmuxd fallback in `DeviceManager`.
  - Single-file IPA staging for faster `Writing to device...`.
  - Optional system `afcclient` fast path for large USB payloads.
  - `[WRITE]` progress/speed telemetry (begin/progress/done with MB/s).
  - Notification proxy timing improvements in `libimobiledevice`.
- Build defaults changed to release (`-O2 -DNDEBUG`), debug build is opt-in via `make DEBUG=1`.
- Added contributor/agent docs and a bench helper script:
  - `CONTRIBUTING.md`
  - `AGENTS.md`
  - `scripts/device-bench.sh`

## Submodule versions

- `libraries/libplist`: `2.7.0` (`cf5897a71ea4`)
- `libraries/libusbmuxd`: `2.1.1` (`adf9c22b9010`)
- `libraries/libimobiledevice`: `1.4.0` + datspike fork `master` patches
- `libraries/ideviceinstaller`: `1.2.0` (`1762d5f12fc5`)
- `libraries/libimobiledevice-glue`: `1.3.2` (`aef2bf0f5bfe`)
- `upstream_repo`: `2ef20b38db9c` + datspike fork `master` patches

## Fast start

Minimal flow with wrapper script:

```bash
# 1) Prepare host: deps + build + anisette (+ AltStore.ipa)
scripts/altstore-linux.sh bootstrap

# 2) (Optional) Refresh AltStore IPA to latest release
scripts/altstore-linux.sh download-altstore

# 3) Install AltStore to iPhone (password prompt with `-`)
scripts/altstore-linux.sh install \
  --udid <UDID> \
  --apple-id <APPLE_ID> \
  --password - \
  --ipa ./AltStore.ipa

# 4) Run daemon (keep it running for AltStore refresh/install)
scripts/altstore-linux.sh daemon --debug-level 0
```

After first install, open iOS Settings and trust the developer app/profile, then try installing any test IPA from AltStore.

Wi-Fi install/refresh is expected when prerequisites are met:
- device is already paired/trusted with this host (usually first pairing via USB);
- iPhone and Linux host are on the same network;
- Wi-Fi sync is enabled for the device (Finder/iTunes setting);
- `usbmuxd`/`netmuxd` path is available (`--prefer-netmuxd` for explicit network path).

## Verified devices

- iPhone 17 Pro (`iOS 26.3`)
- iPhone 13 Pro (`iOS 26.2.1`)

## Usage

- Install IPA: `./build/AltServer-<arch> -u <UDID> -a <APPLE_ID> -p <PASSWORD> <file.ipa>`
- Run daemon: `./build/AltServer-<arch>`
- Help: `./build/AltServer-<arch> --help`

## Build

### Local

```bash
git submodule update --init --recursive
mkdir -p build
cd build
make -f ../Makefile -j3
```

### Docker (CI-like)

```bash
docker run --rm -v ${PWD}:/workdir -w /workdir ghcr.io/nyamisty/altserver_builder_alpine_amd64 \
  bash -lc 'mkdir -p build && cd build && make -f ../Makefile -j3'
```

## Helper CLI

Added wrapper: `scripts/altstore-linux.sh`

```bash
# Full local bootstrap (deps, build, anisette, AltStore IPA)
scripts/altstore-linux.sh bootstrap

# Download latest AltStore IPA to repo root
scripts/altstore-linux.sh download-altstore

# List visible devices
scripts/altstore-linux.sh list-devices

# Install AltStore (defaults to ./AltStore.ipa)
scripts/altstore-linux.sh install --udid <UDID> --apple-id <APPLE_ID> --password -

# Run daemon
scripts/altstore-linux.sh daemon --debug-level 0
```

Draft systemd templates:
- `contrib/systemd/altserver-linux.service`
- `contrib/systemd/altserver-anisette.service`
- `contrib/systemd/netmuxd.service`

Install helper:
`scripts/install-systemd-units.sh`

## Bench / validation helper

```bash
# USB AFC throughput benchmark (MB/s)
scripts/device-bench.sh afc --runs 3 --size-mb 130

# Wi-Fi/netmuxd AFC throughput benchmark (network path)
scripts/device-bench.sh afc --network --mux-socket 127.0.0.1:27015 --udid <UDID> --runs 3 --size-mb 130

# Daemon smoke run with log extraction
scripts/device-bench.sh daemon --altserver ./build/AltServer-x86_64 --seconds 10 --debug-level 1

# AltStore install (prompts for password when --password -)
scripts/device-bench.sh install-altstore \
  --altserver ./build/AltServer-x86_64 \
  --udid <UDID> \
  --apple-id <APPLE_ID> \
  --password - \
  --ipa ./AltStore.ipa
```

## Runtime env vars

- `ALTSERVER_ANISETTE_SERVER`: custom anisette endpoint.
- `ALTSERVER_ANISETTE_SERVERS`: fallback list of anisette endpoints (`url1,url2,...`; also supports `;` and spaces).
- `USBMUXD_SOCKET_ADDRESS`: explicit mux socket (for netmuxd extension mode, usually `127.0.0.1:27015`).
- `ALTSERVER_NETMUXD_SOCKET_ADDRESS`: explicit auto-fallback netmuxd socket.
- `ALTSERVER_DISABLE_AUTO_NETMUXD=1`: disable automatic usbmuxd→netmuxd fallback.
- `ALTSERVER_USE_SYSTEM_AFCCLIENT=1`: enable fast USB upload path via system `afcclient`.
- `ALTSERVER_AFCCLIENT_VERBOSE=1`: extra logs for `afcclient` upload path.

Anisette fallback order:
- if `ALTSERVER_ANISETTE_SERVERS` is set: try endpoints from that list in order;
- otherwise: `ALTSERVER_ANISETTE_SERVER` (or built-in default) → `http://127.0.0.1:6969` → `http://localhost:6969`.
