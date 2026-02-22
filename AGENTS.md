# AGENTS.md — AltServer-Linux

Project-level rules for coding agents working in this repository.

## Opening moves (always)

1. `git status -sb`
2. Confirm active branch and target (`updated-libs`, feature branch, etc.).
3. Read `README.md` and `CONTRIBUTING.md` before non-trivial changes.
4. For submodule work, run `git submodule status --recursive`.

## Scope and intent

- This repo is a Linux port that tracks upstream, then layers minimal Linux-focused changes.
- Optimize for clean history and easy future PRs to upstream projects.
- Prefer targeted fixes over broad refactors.

## Change boundaries

- Preferred edit areas: `src/`, `shims/`, `makefiles/`, docs.
- Avoid direct source edits inside submodules unless explicitly requested.
- If upstream behavior must change, document rationale and keep patch minimal.

## Submodule policy (strict)

- `libraries/*`: pin to stable tags (no pre-release tags).
- `upstream_repo`: pin to explicit SHA (usually `origin/develop` target).
- No local-only detached commits in submodules.
- If library fix is unavoidable:
  - first try workaround in this repo;
  - otherwise use public fork + explicit gitlink commit.

## Build and validation

Primary build:

```bash
git submodule update --init --recursive
mkdir -p build && cd build
make -f ../Makefile -j3
```

Device regression baseline (when touching install/transport flow):

- AltStore install over USB.
- IPA install over USB and Wi-Fi.
- Verify mux path selection (usbmuxd vs netmuxd).
- Track throughput in `MB/s` with explicit formula and test sample size.

Human-in-the-loop checkpoints (trust dialogs, developer confirmation on iOS) are expected; do not fake automation for those steps.

## Commits and reviewability

- Use Conventional Commits.
- Keep commits small and logically scoped.
- Separate docs / build / runtime behavior changes into distinct commits.
- Include short test evidence in commit or PR notes.

## Security and artifact hygiene

Never commit secrets, credentials, provisioning files, pairing material, or bulky generated artifacts.
See `.gitignore` and `CONTRIBUTING.md` for exact categories.

## Documentation quality

- Keep rules concise and stable (avoid task-specific noise).
- Use file references instead of copying long code snippets.
- If a decision is non-trivial and likely to recur, add/update docs rather than embedding ad-hoc notes in commit messages.
