---
name: pre-dispatch-static-audit
description: Before dispatching a long-running CI workflow (chainsaw, terraform-test, integration suite) for this repo, run scripts/pre-chainsaw-audit.sh against the working tree to catch the known classes of CI-discovered bugs (em-dash in tag values, bash-isms in POSIX scripts, v2 condition-array mismatches, namespace binding literals, golden-vs-scenario data drift) in seconds, so the dispatched run iterates on novel bugs rather than re-discovering ones whose fingerprints are already in the codebase. Trigger before any `mcp__*__execute` dispatch of `chainsaw.yml`, before any direct `gh workflow run chainsaw.yml`, or when the user says "dispatch chainsaw", "run chainsaw", "kick off chainsaw", "test the v2 changes via chainsaw". Skip for push-triggered light workflows.
---

# Skill: `pre-dispatch-static-audit`

- **Spec**: `retrospective/2026-05-28-116/SKILL-SPEC-3a7d2e9f1c-pre-dispatch-static-audit.md`
- **AGENTS.md rule**: §6.13

## When to run

Run `bash scripts/pre-chainsaw-audit.sh` before:

- Any dispatch of `.github/workflows/chainsaw.yml` (any `mcp__*__execute` call, any `gh workflow run chainsaw.yml`).
- Any user phrase asking for a chainsaw dispatch ("dispatch chainsaw", "run chainsaw", "kick off chainsaw", "test the v2 changes via chainsaw", "let's see if chainsaw goes green").
- Before opening a PR that touches `tests/chainsaw/`, `crossplane/`, `clusters/`, `argocd/`, `policies/`, or `tests/integration/` and that would trigger `chainsaw-verify.yml` on push.

Do NOT run for:

- Push-triggered light workflows (`unit-tests.yml`, `terraform-validate.yml`) — they finish in < 1 minute and don't benefit.
- Re-dispatching the same SHA with no working-tree changes (the audit's result hasn't changed).

## How to run

```bash
bash scripts/pre-chainsaw-audit.sh
```

The script exits 0 if all six bug-class checks pass (safe to dispatch) and 1 if any fails (do not dispatch — fix the failure first). The output is colourised when run on a terminal; piping to a file produces plain text.

## Interpreting the output

The script runs six numbered checks (A–F), each named for the bug class it catches:

| Check | Bug class | Reference |
|---|---|---|
| A | Non-ASCII in tag-bound `description:` / `Description:` values | AGENTS.md §6.8 ADR-0001 + the auto-003 Strike 1 em-dash fix |
| B | Bash-isms in chainsaw `script.content:` blocks | The auto-003 Strike 3 POSIX-sh fix (`set -o pipefail`) |
| C | Chainsaw `status.conditions:` array doesn't list all 3 v2 conditions | The auto-003 Strike 2 conditions-array fix |
| D | `($namespace)` literal in `apply.resource.metadata.namespace` | The auto-003 PR-T3 Strike 1 composition-drift fix |
| E | Goldens missing explicit `metadata.namespace` | The auto-003 PR-T3 Strike 2 golden-namespace fix |
| F | Golden `Description:` text doesn't match the scenario's XR `spec.description` | The auto-003 PR-T3 Strike 4 em-dash-in-golden fix |

Each FAIL prints the file + line(s) + a one-sentence explanation. Fix the failure, then re-run the audit. Re-dispatch chainsaw only after the audit is GREEN.

## When the audit comes back GREEN

Dispatch chainsaw with one `mcp__*__execute` call (or `gh workflow run chainsaw.yml`), then set up a single background poll per AGENTS.md §6.10. Do not call any status-query tool until the poll's completion notification fires.

## When the audit comes back RED

Do NOT dispatch chainsaw. Fix every FAIL. Re-run the audit. Iterate until GREEN. Dispatching with FAIL'd checks is a violation of AGENTS.md §6.13 — the dispatched run is expected to fail with the exact pattern the audit flagged, and the iteration burns CI wall-clock the audit could have prevented in seconds.

## Files this skill creates or modifies

This is a read-only skill. It invokes `scripts/pre-chainsaw-audit.sh`, which inspects the working tree but never modifies it. The user fixes flagged issues by editing the offending files manually before re-running.

## See also

- `scripts/pre-chainsaw-audit.sh` — the audit driver.
- AGENTS.md §6.8 — live-admission verification for v2 Crossplane CRD changes (the rule the audit's Check A defends).
- AGENTS.md §6.10 — never foreground-poll a long-running CI run (what to do AFTER the audit comes back GREEN and chainsaw is dispatched).
- AGENTS.md §6.13 — the rule this skill operationalizes.
- `retrospective/2026-05-28-116/SKILL-SPEC-3a7d2e9f1c-pre-dispatch-static-audit.md` — the full spec.
