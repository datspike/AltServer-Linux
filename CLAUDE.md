# CLAUDE.md

Short entrypoint for Claude/Codex-style agents in this repository.

## Read first

1. `AGENTS.md`
2. `CONTRIBUTING.md`
3. `README.md`

## Build quickstart

```bash
git submodule update --init --recursive
mkdir -p build && cd build
make -f ../Makefile -j3
```

## Core expectations

- Keep changes minimal and reviewable.
- Respect submodule pinning policy (`libraries/*` stable tags, `upstream_repo` explicit SHA).
- Validate behavior on real device flows when touching install/mux/write stages.
- Never commit secrets or generated artifacts.
