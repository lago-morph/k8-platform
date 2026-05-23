# AGENTS.md suggestion: CLAUDE.md stays a pointer; AGENTS.md is canonical

## Proposed addition

> **§1.1 CLAUDE.md is a pointer; AGENTS.md is canonical.** All
> agent instructions live in `AGENTS.md` at the repo root.
> `CLAUDE.md` exists only as a pointer for the Claude Code
> convention, and contains nothing but a one-line reference to
> `AGENTS.md`.
>
> When updating agent instructions: edit `AGENTS.md`; do not
> duplicate content into `CLAUDE.md`.
>
> *Grounded in: PR #35 consolidation, where CLAUDE.md was
> reduced to a pointer to avoid two-files-of-truth drift.*

## Why this earns its place in your agents file

Cross-agent conventions are stabilizing on AGENTS.md as the
canonical location. Keeping two files in sync is a maintenance
hazard the project explicitly chose to avoid. The rule prevents a
future agent from "helpfully" adding instructions back to
CLAUDE.md.
