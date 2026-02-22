# WORK_REPORT — updated-libs

Date: 2026-02-22

## Scope completed

1. Created clean public fork baseline from `NyaMisty/AltServer-Linux:new`.
2. Created branch `updated-libs` from that baseline.
3. Added contributor and agent governance docs:
   - `CONTRIBUTING.md`
   - `AGENTS.md`
   - `CLAUDE.md`
   - scoped rules in `src/AGENTS.md` and `makefiles/AGENTS.md`
4. Updated core submodules to latest stable / latest develop target.
5. Fixed build breakages introduced by dependency API drift.
6. Ported required runtime/perf fixes from `working-26.3`.
7. Added benchmark automation helper: `scripts/device-bench.sh`.
8. Updated `README.md` with deltas, versions, and validation status.
9. Extended bench helper with explicit network mode and per-run timeout guards.

## Fork/repo state

- Main fork: `https://github.com/datspike/AltServer-Linux`
- Base refs synced:
  - `fork/new` = `origin/new` = `78764512b735e7a731ef4ff36aca8d80dbd8d7c8`
  - `fork/master` initialized from same clean SHA

## Dependency state (current)

- `libraries/libplist`: `2.7.0` (`cf5897a71ea4`)
- `libraries/libusbmuxd`: `2.1.1` (`adf9c22b9010`)
- `libraries/libimobiledevice`: `64a909f67185` (fork branch `updated-libs-patches`, based on `1.4.0`)
- `libraries/ideviceinstaller`: `1.2.0` (`1762d5f12fc5`)
- `libraries/libimobiledevice-glue`: `1.3.2` (`aef2bf0f5bfe`)
- `upstream_repo` (`AltServer-Windows`): `a2819291f52b` (fork branch `updated-libs-patches`, based on `2ef20b38db9c`)

## Fixes applied after baseline

### Build/API compatibility

- `makefiles/AltSign-build/rewrite_altsign_source.py`
  - adapted `plist_from_memory` calls to current `libplist` signature.
- `makefiles/rewrite_altserver_source.py`
  - adapted plist call signatures in patched AltServer sources.
  - removed direct dependency on internal `libimobiledevice/src/idevice.h`.
- `makefiles/libimobiledevice-build/libimobiledevice-files.mak`
  - include path adjustment for current header layout.
- `src/common.h`
  - added missing C++ include for `std::shared_ptr` usage path.

### Performance and runtime behavior

- Default release build (`-O2 -DNDEBUG`) with `DEBUG=1` opt-in.
- Ported upstream-side fixes (from `working-26.3`) into forked `AltServer-Windows`:
  - single-file IPA staging path,
  - `[WRITE]` MB/s telemetry,
  - optional `ALTSERVER_USE_SYSTEM_AFCCLIENT=1`,
  - USB-first + netmuxd fallback lookup strategy,
  - robust `Archiver` buffer lifetime handling.
- Ported `libimobiledevice` fixes into fork:
  - notification proxy timing improvements (lower timeout, remove extra sleep),
  - AFC write behavior/perf patches used in 26.3.

## Validation executed

### Build

- Docker build (`ghcr.io/nyamisty/altserver_builder_alpine_amd64`): PASS.
- Produced binary: `build/AltServer-x86_64`.
- First-run pulls for non-amd64 builder images started but were too slow to finish in-session.

### Device/runtime

- USB device detection in daemon smoke: PASS.
- Notification connection startup observed in daemon logs: PASS.

### Throughput

- USB AFC benchmark (`scripts/device-bench.sh afc --runs 3 --size-mb 130`):
  - runs: `35.406`, `35.397`, `35.406` MB/s
  - median: `35.406 MB/s`
  - p95: `35.406 MB/s`
  - gate `>=20 MB/s`: PASS
- Wi-Fi/netmuxd AFC benchmark attempt:
  - command: `scripts/device-bench.sh afc --network --mux-socket 127.0.0.1:27015 --runs 1 --size-mb 130 --timeout-seconds 20`
  - result: timed out (`rc=124`) on `afcclient -n`; network AFC path requires manual validation in target setup.

### Pending manual/human-in-loop tests

- End-to-end AltStore install from this branch (requires Apple ID credentials and device trust confirmations).
- End-to-end IPA install via AltStore over USB and Wi-Fi.
- Wi-Fi/netmuxd speed gate (netmuxd lists network UDIDs, but AFC operation times out in this environment).
- Explicit auto-select verification during real install request path (requires active install flow).

## Fallback/fork details

Forks created for patched submodules:

- `https://github.com/datspike/AltServer-Windows` (branch: `updated-libs-patches`)
- `https://github.com/datspike/libimobiledevice` (branch: `updated-libs-patches`)

Prepared compare/PR entry points:

- `https://github.com/datspike/AltServer-Windows/compare/master...updated-libs-patches`
- `https://github.com/datspike/AltServer-Windows/pull/new/updated-libs-patches`
- `https://github.com/datspike/libimobiledevice/compare/master...updated-libs-patches`
- `https://github.com/datspike/libimobiledevice/pull/new/updated-libs-patches`

`.gitmodules` updated to point these two submodules to datspike forks.

## PR candidate list

1. `AltServer-Linux` upstream PR candidate:
   - dependency bumps + build compatibility layer updates + docs/bench script.
2. `AltServer-Windows` PR candidates (split by concern):
   - `DeviceManager` write telemetry + single-file staging.
   - USB-first/netmuxd fallback lookup logic.
   - `Archiver` zip buffer lifetime fix.
3. `libimobiledevice` PR candidates:
   - notification proxy responsiveness patch.
   - AFC write throughput/reliability patches.

## Notes

- `scripts/device-bench.sh` is designed to keep human confirmation steps explicit while automating timing and MB/s calculations.
- MB/s is consistently reported as decimal (`bytes / seconds / 1_000_000`).
