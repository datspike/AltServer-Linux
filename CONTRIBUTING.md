# Contributing to AltServer-Linux

This repository tracks `NyaMisty/AltServer-Linux` and keeps Linux-specific improvements reviewable for future upstream PRs.

## Goals

- Keep changes small, explicit, and easy to review.
- Prefer fixes in our Linux layer (`src/`, `shims/`, `makefiles/`) over invasive rewrites.
- Keep submodule updates deterministic (stable tags / known SHAs).

## Repository map

- `src/` — Linux overrides for upstream AltServer sources.
- `shims/` — Windows-to-POSIX compatibility layer.
- `makefiles/` — build orchestration and rewrite scripts.
- `libraries/` — third-party submodules (`libimobiledevice*`, `libplist`, `ideviceinstaller`, `dnssd_loader`).
- `upstream_repo/` — upstream `AltServer-Windows` submodule (usually `develop` branch SHA).
- `buildenv/` — Docker build environment scripts.

## Local build

```bash
git submodule update --init --recursive
mkdir -p build
cd build
make -f ../Makefile -j3
```

Output binary: `build/AltServer-<arch>` (`arch` from `gcc -dumpmachine`).

## Docker/CI-equivalent build

Use the same flow as CI (`.github/workflows/build.yml`) with the project builder images:

```bash
docker run -v ${PWD}:/workdir -w /workdir <builder-image> bash -lc 'mkdir -p build && cd build && make -f ../Makefile -j3'
```

## Submodule update policy

Top-level submodules in `.gitmodules` are updated independently:

- `libraries/libplist`
- `libraries/libusbmuxd`
- `libraries/libimobiledevice`
- `libraries/ideviceinstaller`
- `libraries/libimobiledevice-glue`
- `upstream_repo`

Rules:

1. For `libraries/*`: move to latest stable tag (no `-rc`, `-beta`, `-alpha`).
2. For `upstream_repo`: move to target upstream SHA (typically latest `origin/develop`).
3. Do not leave local-only commits inside submodules.
4. If a library patch is required:
   - first try a workaround in this repo (`src/`, `makefiles/`, shims);
   - if impossible, use a public fork + separate commit updating submodule URL/gitlink.

Suggested commit messages:

- `chore(submodule): bump libplist to vX.Y.Z`
- `chore(submodule): bump upstream_repo to <sha>`
- `chore(submodule): point libimobiledevice to datspike fork`

## Device validation matrix

Minimum validation before merge:

1. AltStore install over USB.
2. IPA install in AltStore over USB.
3. IPA install in AltStore over Wi-Fi / netmuxd.
4. Auto mux behavior:
   - USB path prefers usbmuxd for wired devices.
   - Wi-Fi-only path works via netmuxd.

Speed gate (for regression checks):

- Unit: `MB/s` (`bytes / seconds / 1_000_000`).
- Baseline target: median `>= 20.0 MB/s` with AFC write chunk `512 KiB`.
- Recommended runs: at least 3 USB + 3 Wi-Fi runs, report median and p95.

Human-in-the-loop:

- iOS trust / developer confirmation prompts are manual and expected.
- Note explicitly in test reports where manual confirmation was required.

## Commits and PRs

Use Conventional Commits and keep each commit focused:

- `fix(mux): ...`
- `fix(build): ...`
- `perf(write): ...`
- `docs(contributing): ...`

PR checklist:

- [ ] Small, coherent commit set.
- [ ] Build succeeds locally (and ideally Docker/CI-equivalent).
- [ ] Device validation summary included (USB/Wi-Fi, timing, MB/s).
- [ ] Submodule versions/SHAs documented in PR body.
- [ ] No unrelated refactors.

## Security and hygiene

Never commit:

- Apple ID credentials, app-specific passwords, session cookies.
- Provisioning materials: `.p12`, `.mobileprovision`, pairing artifacts.
- Runtime/build artifacts: `AltServerData/`, `*_patched/`, `build*/`, static archives, large IPA files.
- Raw crash dumps containing personal identifiers unless redacted.

If logs contain UDID, Apple account, or local paths, redact before publishing.
