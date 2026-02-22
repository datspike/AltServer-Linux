# AGENTS.md (src/)

Rules for `src/` overrides:

- Keep overrides narrowly Linux-specific.
- Preserve upstream behavior unless change is intentional and documented.
- Prefer adding small compatibility shims over rewriting larger flows.
- When fixing runtime issues, include a concise reproduction note in commit/PR text.
