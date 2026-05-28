# Spec: `pre-dispatch-static-audit`

- **ID**: SKILL-SPEC-3a7d2e9f1c
- **Source retrospective**: ../2026-05-28-116.md

## Intent

Run a single-pass static audit against the changed files in the working tree before dispatching a long-running CI workflow. Catches the known classes of CI-discovered bugs (em-dash in tag values, bash-isms in POSIX scripts, v2 condition-array mismatches, namespace-binding literals, golden-vs-scenario data drift) in seconds, so the dispatched run iterates on novel bugs rather than re-discovering ones whose fingerprints are already in the codebase.

## Trigger

Activate before any of these tool calls when the working tree has uncommitted or recently-committed changes under `tests/chainsaw/`, `crossplane/`, `clusters/`, `argocd/`, `policies/`, or `tests/integration/`:

- `mcp__*__execute` dispatching `chainsaw.yml` (or any other `workflow_dispatch` workflow on a long-running pipeline)
- Direct `gh workflow run chainsaw.yml`
- Any user phrase like "dispatch chainsaw", "run chainsaw", "kick off chainsaw", "test the v2 changes via chainsaw"

Do NOT activate for:
- Push-triggered light workflows (`unit-tests.yml`, `terraform-validate.yml`) — those finish in <1 min and don't benefit from pre-dispatch audit
- Re-dispatching the same SHA with no working-tree changes

## Inputs

- Current working tree (uncommitted changes)
- Most recent commits on the current branch since `origin/main`
- Optional: explicit file list (skill argument)

## Outputs

- Stdout report: per-bug-class pass/fail with file:line references
- Exit code 0 if all clean (dispatch is safe); exit 1 if any bug class fires (dispatch will likely fail; fix first)

## Workflow

1. Enumerate changed YAML / shell files since last push: `git diff --name-only origin/main...HEAD; git status --porcelain | awk '{print $2}'`. Filter to cluster-bound paths.
2. Run each of these checks in sequence, accumulating a pass/fail report. Each check is one-liner-fast.
3. **Check A — em-dash in tag-bound description fields**: scan files under `tests/chainsaw/`, `crossplane/claims/`, `crossplane/xrds/*/render-fixtures/`, `tests/integration/` for non-ASCII bytes in lines matching `^\s*(description|Description):`. Strip YAML comments first.
4. **Check B — bash-isms in chainsaw script blocks**: grep `tests/chainsaw/**/*chainsaw-test.yaml` for `set -.*pipefail`, `[[ `, `<<<`, `(( `, `<(`, `>(`, brace expansion. Each match is a fail.
5. **Check C — v2 XR conditions array length**: for each `chainsaw-test.yaml` containing `kind: XPlatform*` and `status:\s+conditions:`, verify the array has exactly 3 entries (Synced, Ready, Responsive) in the canonical order.
6. **Check D — `($namespace)` literal in apply.resource.metadata.namespace**: grep for `apply:` blocks under `chainsaw-test.yaml` files where `metadata.namespace` is `($namespace)` — chainsaw schema validation rejects this pre-substitution.
7. **Check E — golden-vs-scenario data-value consistency**: for each `expected/*.yaml` golden under chainsaw scenarios, find the corresponding scenario's `apply.resource` and verify that any field flowing through the Composition into the golden (notably `spec.description` → `tags.Description`) matches byte-for-byte.
8. **Check F — namespace binding literal in golden metadata**: golden YAMLs should have a concrete `metadata.namespace` (e.g., `default`), not the chainsaw binding `($namespace)` (which doesn't substitute in `assert: file:` form).
9. Print a one-line summary per check (PASS / FAIL with count + first-3-locations). Exit 0 iff all PASS.

## Concrete examples

**Example 1 — auto-003 PR #111 pre-dispatch state on Strike 1 (commit `d274efc`)**:

Audit would fire:
- Check A (em-dash): FAIL — 5 hits in `tests/chainsaw/_meta/composition-drift/chainsaw-test.yaml`, `crossplane/xrds/platform-secret/render-fixtures/input.yaml`, 3 asm-secret goldens
- Check D (`($namespace)` literal): FAIL — 1 hit in `tests/chainsaw/_meta/composition-drift/chainsaw-test.yaml:51`
- Check F (golden namespace): FAIL — 6 hits across goldens missing `metadata.namespace: default`

Three of the five chainsaw iterations would be eliminated, saving roughly 30 minutes of CI wall-clock.

**Example 2 — auto-003 PR #105 pre-dispatch state on Strike 1 (commit `6a47acf`)**:

Audit would fire:
- Check A (em-dash): FAIL — 4 hits in `tests/chainsaw/platform-secret/*/chainsaw-test.yaml` + 1 in `crossplane/claims/example-platform-secret.yaml`
- Check B (bash-isms): FAIL — 4 hits across 3 scenario script blocks
- Check C (3 conditions): FAIL — 3 scenarios assert `[Ready]` or `[Synced, Ready]` against v2 XRs

All three of the PR #105 layered chainsaw iterations would be eliminated in a single static pass.

## Anti-patterns

- **Skipping the audit because "the change is small"**: layered bugs hide in small changes. A 5-line scenario edit can carry a bash-ism that costs 15 minutes of CI.
- **Running the audit but ignoring a FAIL**: defeats the purpose. If a check fails, fix it before dispatching.
- **Adding checks for bug classes you've never seen**: the audit's value is catching KNOWN-recurring bug classes; speculative checks bloat it without value.

## Acceptance criteria

1. Skill runs in under 5 seconds on the full repo.
2. Each known bug class (em-dash, bash-isms, conditions array, namespace literals, golden consistency) is covered by exactly one check.
3. Each FAIL output names the file + line + a one-sentence explanation of why it'll fail at chainsaw time.
4. Exit code 0 iff all checks PASS; exit 1 otherwise.
5. Idempotent — re-running with no changes produces identical output.

## Files this skill creates / modifies

- `scripts/pre-chainsaw-audit.sh` — the audit driver (new file).
- No changes to existing files at runtime; the skill is a validator, not a fixer.

The user fixes failed checks manually before re-running.
