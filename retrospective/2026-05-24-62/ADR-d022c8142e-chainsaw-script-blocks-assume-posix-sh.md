# ADR: Chainsaw script: blocks assume POSIX sh

- **ID**: ADR-d022c8142e
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-05-24
- **Source retrospective**: ../2026-05-24-62.md
- **PRs covered**: #53

## Context

PR #53 hit the failure four times across chainsaw iterations: `sh: 1: set: Illegal option -o pipefail`. Each iteration cost ~7 minutes of CI. The pipefail pattern had propagated across the codebase via copy-paste because bash is the default elsewhere; the chainsaw `script:` context was the exception that mattered.

## Decision

Chainsaw's `script:` step body MUST use only POSIX-sh-compatible code (Ubuntu 24.04's `/usr/bin/sh` is `dash`); `set -eu` instead of `set -euo pipefail`; no `[[ ... ]]`, bash arrays, or process substitution. For pipefail semantics, restructure to avoid pipes or move the logic into `tests/chainsaw/run.sh` which runs in bash.

## Alternatives considered

- **Add a bash wrapper to chainsaw script: blocks (`bash -c 'set -euo pipefail; ...'`)** — rejected as boilerplate that obscures the test logic.
- **Switch to bash by changing chainsaw's shell config** — chainsaw v0.2.12 doesn't expose a shell override; would require upstream change.
- **Document the rule without lint enforcement** — rejected; the pattern will recur on copy-paste.

## Consequences

**Easier:** chainsaw scenarios reliably executable on any POSIX-sh runner; explicit dialect boundary. **Harder:** authoring chainsaw scenarios requires a mental context-switch from bash to POSIX. **Trade-off:** small authoring discipline for cross-runner reliability.

## References

- [`../2026-05-24-62.md`](../2026-05-24-62.md) — the source retrospective.
- [`./SKILL-SPEC-085176fac1-chainsaw-script-dialect-awareness.md`](./SKILL-SPEC-085176fac1-chainsaw-script-dialect-awareness.md) — related skill spec.
- [`./SKILL-SPEC-9149cdc0a6-tdd-lint-bug-class.md`](./SKILL-SPEC-9149cdc0a6-tdd-lint-bug-class.md) — related skill spec.
- PRs the decision was made in: #53.
