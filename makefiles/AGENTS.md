# AGENTS.md (makefiles/)

Rules for build-system changes:

- Keep build edits minimal and architecture-safe.
- Prefer deterministic flags and explicit include/link updates.
- Avoid hidden behavior changes in rewrite scripts without documenting intent.
- Any performance flag change must be validated by at least one successful build.
