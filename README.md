# AltServer-Linux (updated-libs fork)

Linux port of AltServer with an updated dependency stack and USB/Wi-Fi install-path fixes.

Base reference: `NyaMisty/AltServer-Linux` branch `new` (`78764512`).

## What changed vs `NyaMisty/new`

- Dependency refresh to current stable tags (`libplist`, `libusbmuxd`, `libimobiledevice`, `ideviceinstaller`, `libimobiledevice-glue`) and latest `upstream_repo` `develop`.
- Additional runtime fixes ported from `working-26.3` onto latest upstream:
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
- `libraries/libimobiledevice`: `1.4.0` + local patch branch (`updated-libs-patches`)
- `libraries/ideviceinstaller`: `1.2.0` (`1762d5f12fc5`)
- `libraries/libimobiledevice-glue`: `1.3.2` (`aef2bf0f5bfe`)
- `upstream_repo`: `2ef20b38db9c` + local patch branch (`updated-libs-patches`)

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

## Bench / validation helper

```bash
# USB AFC throughput benchmark (MB/s)
scripts/device-bench.sh afc --runs 3 --size-mb 130

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
- `USBMUXD_SOCKET_ADDRESS`: explicit mux socket (for netmuxd extension mode, usually `127.0.0.1:27015`).
- `ALTSERVER_NETMUXD_SOCKET_ADDRESS`: explicit auto-fallback netmuxd socket.
- `ALTSERVER_DISABLE_AUTO_NETMUXD=1`: disable automatic usbmuxd→netmuxd fallback.
- `ALTSERVER_USE_SYSTEM_AFCCLIENT=1`: enable fast USB upload path via system `afcclient`.
- `ALTSERVER_AFCCLIENT_VERBOSE=1`: extra logs for `afcclient` upload path.

## Current validation snapshot

- Docker build (`amd64`): pass.
- Daemon smoke with USB-connected iPhone: pass (device detected, notification connection starts).
- USB AFC benchmark (`130 MB`, 3 runs): median `36.158 MB/s`, p95 `36.351 MB/s`.
- Wi-Fi/netmuxd benchmark: requires a network-visible device on netmuxd socket.

## Known limitations

- iOS trust / developer confirmation dialogs are manual (human-in-the-loop).
- Full end-to-end AltStore install/IPA tests require Apple ID credentials and device interaction.
- Multi-arch container pulls can be slow on first run (large builder images).
