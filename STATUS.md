# Status log

Recent/active work, newest entry on top. One entry per chunk of work — what changed, why,
and what's left/next if anything. Standing project info (architecture, how things work)
belongs in `AGENTS.md`, not here. When this file gets long, move older entries into
`STATUS_ARCHIVE.md` (keep the newest ~10-15 entries here).

---

## 2026-07-20 — Claude — docs: split CLAUDE.md into AGENTS.md + STATUS.md + STATUS_ARCHIVE.md

Set up shared docs so Claude Code and Codex sessions can hand off work to each other.
`CLAUDE.md`'s content (all of it was project info, nothing Claude-Code-specific) moved to
`AGENTS.md` verbatim; `CLAUDE.md` is now a short pointer to `AGENTS.md`/`STATUS.md` (kept
so Claude Code still auto-loads it). Added this `STATUS.md` for task-entry logging and an
empty `STATUS_ARCHIVE.md` for overflow.

No code changes. Nothing else in flight from this session.
