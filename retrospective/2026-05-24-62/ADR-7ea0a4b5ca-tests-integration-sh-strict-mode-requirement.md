# ADR: tests/integration/*.sh strict-mode requirement

- **ID**: ADR-7ea0a4b5ca
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-05-24
- **Source retrospective**: ../2026-05-24-62.md
- **PRs covered**: #59

## Context

Integration-tests run 26347839740 silently reported PASS while four `wait_for` calls timed out and the K8s Secret never materialized. Root cause: (a) `tests/integration/11_platform_secret_e2e.sh` used `UID=$(kubectl get ...)` — bash refused the assignment because `$UID` is a readonly builtin; `$UID` retained the runner's process UID (1001); downstream `ASM_KEY=k8-platform/1001` collided across runs. (b) All 11 integration scripts used `set -uo pipefail` without `-e`, so `wait_for` returning 1 on timeout did not abort the script. PR #59 shipped two TDD lints with the fixes.

## Decision

Every script under `tests/integration/NN_*.sh` MUST use `set -euo pipefail` (or `set -eu` where pipefail is unwanted) and MUST NOT assign to bash readonly built-in variables (`UID`, `EUID`, `BASHPID`, `RANDOM`, `LINENO`, `SECONDS`). Enforced by `tests/unit/test_integration_scripts_strict_mode.sh` and `tests/unit/test_shell_readonly_var_assignment.sh`.

## Alternatives considered

- **Migrate all 11 scripts to a stricter test framework (bats, shellspec)** — rejected as scope creep; lints are sufficient for the specific failure modes.
- **Lint only the integration scripts where bugs were observed** — rejected because the bug class can recur in any future integration script.
- **Document the rule in a comment without lint enforcement** — rejected as toothless; future agents will copy bad patterns.

## Consequences

**Easier:** integration scripts fail loud on assertion failure; bash readonly assignment shadows caught at lint time. **Harder:** more strict mode means `set -e` interactions need care (e.g., `command || true` patterns explicit). **Trade-off:** small authoring discipline for permanent silent-PASS prevention.

## References

- [`../2026-05-24-62.md`](../2026-05-24-62.md) — the source retrospective.
- [`./SKILL-SPEC-9149cdc0a6-tdd-lint-bug-class.md`](./SKILL-SPEC-9149cdc0a6-tdd-lint-bug-class.md) — related skill spec.
- PRs the decision was made in: #59.
