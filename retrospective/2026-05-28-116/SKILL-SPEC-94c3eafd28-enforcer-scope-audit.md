# Spec: `enforcer-scope-audit`

- **ID**: SKILL-SPEC-94c3eafd28
- **Source retrospective**: ../2026-05-28-116.md

## Intent

When the agent writes a new unit-test enforcer for a class of bugs, force a one-shot scope-survey step before the `find` arguments in the enforcer are committed. Surveys the entire repo for the bug-class fingerprint, enumerates every directory where the pattern appears or could appear, and includes all of them in the enforcer's `find` paths. Prevents the recurring "enforcer scope was too narrow because I only looked where the first bug bit me" failure mode.

## Trigger

Activate when the agent is about to commit a new `tests/unit/test_*.sh` file that includes a `find <paths>` statement, or when the agent is editing the `find` paths of an existing enforcer:

- New file with `find` at the top, looking for a pattern (em-dash, regex, YAML key, etc.)
- Diff that adds or modifies a `find <dir>` argument in `tests/unit/test_*.sh`
- User phrase like "write an enforcer for X", "prevent regressions on Y", "make sure Z doesn't happen again"

Do NOT activate for:
- Edits that change the enforcer's pattern but not its scope
- Enforcers whose scope is explicitly bounded (e.g., "this test only applies to platform-secret scenarios")

## Inputs

- The bug-class pattern (regex / string / structural)
- The currently-proposed scope (`find <these dirs>`)
- The repo working tree

## Outputs

- A scope-survey report: directories where the pattern appears OR where it could plausibly appear
- A recommended scope list (union of currently-proposed + survey-discovered)
- A diff against the currently-proposed scope, showing what's missing

## Workflow

1. Extract the pattern from the proposed enforcer (the `grep -nE '<PATTERN>'` line or equivalent).
2. Run `grep -rln '<PATTERN>' .` excluding `.git/`, `node_modules/`, `kubeconform-schemas/`, `retrospective/`, `docs/`. Capture every file that matches.
3. Reduce to the set of unique directories.
4. Compare against the currently-proposed `find` paths.
5. If the survey discovers directories NOT in the proposed scope:
   a. Report each one with the count of matches.
   b. Categorize each as: "currently has the bug-class — definitely include", "could have the bug-class structurally — probably include", "would never have the bug-class — safe to exclude".
   c. Recommend a widened scope (union of proposed + categories 1+2).
6. Emit a diff the agent can apply to the enforcer's `find` arguments.

## Concrete examples

**Example 1 — `test_chainsaw_tag_chars.sh` in PR #105 commit `d843915`**:

Proposed scope: `find tests/chainsaw/platform-secret crossplane/claims -name '*.yaml'`.
Pattern (paraphrased): `^\s*description:` + non-ASCII byte.

Survey result: pattern appears in `tests/chainsaw/_meta/composition-drift/chainsaw-test.yaml`, `tests/chainsaw/platform-secret/*/expected/*.yaml`, `crossplane/xrds/platform-secret/render-fixtures/input.yaml`, `tests/integration/11_platform_secret_e2e.sh` — ALL outside the proposed scope.

Recommended widened scope: `find tests/chainsaw crossplane/claims crossplane/xrds/*/render-fixtures tests/integration -name '*.yaml' -o -name '*.sh'`.

Without this skill, the narrow scope shipped and the bug class reappeared in PR #111 four chainsaw iterations later.

**Example 2 — `test_chainsaw_xr_conditions_complete.sh` in PR #105 commit `8298c1f`**:

Proposed scope: `find tests/chainsaw/platform-secret tests/chainsaw/platform-cluster -name 'chainsaw-test.yaml'`.
Pattern: `status:\s*\n\s*conditions:` inside a `kind: XPlatform*` assert.

Survey result: pattern appears in `tests/chainsaw/_meta/composition-drift/chainsaw-test.yaml` — outside proposed scope.

Recommended widened scope: `find tests/chainsaw -name 'chainsaw-test.yaml'` (drop the per-XR-kind subdirectory limit).

Without this skill, the narrow scope shipped and the bug class reappeared in PR #111's composition-drift chainsaw failure.

## Anti-patterns

- **Surveying only inside the enforcer's currently-proposed scope**: the whole point is to look OUTSIDE the proposed scope for missed directories.
- **Treating every directory with a match as automatically in-scope**: documentation files (`retrospective/`, `docs/`, `*.md`) often legitimately carry the bug-class pattern in narrative; those should be excluded by category not by guess.
- **Skipping the survey because "I'm only looking for one instance"**: enforcers exist to prevent recurrence; the recurrence will happen in a directory you didn't think of.

## Acceptance criteria

1. Survey covers the entire repo (minus `.git/`, `node_modules/`, schema stores, retrospectives, docs).
2. Every directory with a current pattern match is reported.
3. The recommended scope is at least the union of the proposed scope and the survey-discovered directories.
4. The skill produces a diff against the enforcer's `find` arguments that the agent can apply mechanically.

## Files this skill creates / modifies

- No files at runtime; the skill is advisory. The agent applies the recommended scope manually to the enforcer's `find` arguments before committing.
