# SPEC-D3 — Delete `chainsaw-verify.yml` and add re-emergence lint

Brainstorm IDs: **A6-008** (delete verifier) + **A6-009** (lint follow-up,
cross-comment A3→A6-002). Tier D item D3 in
`ai/brainstorming/specs/larger-list-preferences.md`.

---

## 1. Summary

Delete `.github/workflows/chainsaw-verify.yml` — the lightweight SHA-
handshake verifier whose only purpose was to prove the agent had already
dispatched `chainsaw.yml` against the current commit before opening a PR.
The verifier existed because chainsaw could not be run locally; with direct
sandbox compute `bash tests/chainsaw/run.sh` is the authoritative test and
the dispatch-then-verify indirection is dead weight. Alongside the deletion,
collapse `chainsaw.yml`'s `workflow_dispatch`-only trigger to add a `push`
trigger (A6-009) and add a new lint at
`tests/unit/test_no_sha_verifier_pattern.sh` (cross-comment A3→A6-002) that
statically asserts no workflow reintroduces the dispatch-then-verify
handshake. AGENTS.md §6.7 is updated to retire chainsaw from the heavy-CI-
workflow contract. Net result: ~130 lines of workflow YAML removed, chainsaw
CI becomes deterministic on push, and the manual four-step dispatch ceremony
is gone. Part of the Tier D cruft-removal cluster in
`larger-list-preferences.md`.

---

## 2. Retro pain killed

- **Dispatch round-trip friction.** AGENTS.md §6.7's operating contract
  required push → dispatch → wait → open-PR on every chainsaw-touching PR.
  Each iteration added ~5 minutes of wall-clock delay and a manual
  `gh workflow run` invocation. With sandbox compute the agent runs
  `bash tests/chainsaw/run.sh` directly; the four-step ceremony is
  eliminated.

- **SPEC-A4 §8 acknowledged the verifier as a surviving constraint.**
  SPEC-A4 §8 noted `chainsaw-verify.yml` was unaffected; this spec removes
  that constraint so future agents do not inherit the indirection.

- **SHA-mismatch silent failures.** A `git commit --amend` or force-push
  after the dispatch step produced an unhelpful `❌ No green Chainsaw run
  found for commit <SHA>` failure. Several prior-session iteration loops
  were attributable to this mismatch class.

- **A3→A6-002 documented re-emergence risk.** Agent A3 flagged that
  deleting the file without a lint leaves the repo open to a future agent
  reinstating an equivalent handshake under a different filename. The lint
  at §4 closes that regression path.

- **`commit_sha` dispatch input was dead code.** The only caller was the
  verifier. Orphaned inputs accumulate confusion; removal is clean.

---

## 3. Out of scope

- **SPEC-A4 `catch:` block work.** Scenario diagnostics are SPEC-A4's scope.
  **Dependency:** this spec should land after or alongside SPEC-A4 (PR-S.1
  catch hook) so push-triggered CI failures are self-diagnosable. See §5.4.

- **`chainsaw-evidence-bundler.sh`** (brainstorm A1→A6-002). Preserving the
  "evidence quote" value of the old verifier's API-query output is a useful
  follow-on but does not affect test coverage. Deferred.

- **`runbook-verify-then-pr.md`** (brainstorm A4→A6-008). Deferred; this
  spec retires only the chainsaw instance of the pattern.

**Considered and rejected:**

- *Keeping `commit_sha` as an optional input.* No caller passes it with the
  verifier gone; dead inputs mislead future agents. Removed.
- *E2E smoke test asserting push triggers chainsaw exactly once.* Requires a
  live Actions run; infeasible as a unit test. The static lint is the
  tractable substitute.

---

## 4. Files to change / create

**Delete:**

- `/home/user/k8-platform/.github/workflows/chainsaw-verify.yml`
  — Remove entirely. No replacement.

**Modify:**

- `/home/user/k8-platform/.github/workflows/chainsaw.yml`
  — Remove the `commit_sha` dispatch input. Add a `push` trigger block with
  `branches-ignore: [main]` and the same `paths:` filter that
  `chainsaw-verify.yml` currently carries (minus the self-reference). Remove
  the 10-line comment block (lines 20–30) explaining the old dispatch-then-
  verify flow; replace with `# Runs on push (path-filtered) and on
  workflow_dispatch for manual re-runs.`

- `/home/user/k8-platform/AGENTS.md`
  — §6.7: Remove the `chainsaw.yml ↔ chainsaw-verify.yml` bullet. Remove
  the four-step operating contract steps that reference chainsaw. Add a
  one-sentence citation of `tests/unit/test_no_sha_verifier_pattern.sh`
  as the guard against pattern re-emergence.

**Create:**

- `/home/user/k8-platform/tests/unit/test_no_sha_verifier_pattern.sh`
  — New lint. Covers A6-009 / A3→A6-002. See §5 for full design.

- `/home/user/k8-platform/tests/unit/fixtures/sha-verifier-lint/bad-verifier.yml`
  — Synthetic adversarial fixture with all three bad-pattern signatures.
  Used by the lint's meta-test to prove it actually fires.

---

## 5. Implementation notes

### 5.1 `chainsaw.yml` trigger replacement

```yaml
on:
  push:
    branches-ignore:
      - main
    paths:
      - ".github/workflows/chainsaw.yml"
      - "crossplane/**"
      - "tests/chainsaw/**"
      - "tests/unit/test_chainsaw_kind_config.sh"
  workflow_dispatch:
    inputs:
      scenario_filter:
        description: "Optional path filter passed as CHAINSAW_SCENARIOS (default: all)"
        required: false
        default: ""
```

The `commit_sha` input is dropped; `scenario_filter` is kept for operator
spot-checks. `paths:` mirrors `chainsaw-verify.yml`'s current filter minus
its self-reference entry.

### 5.2 Lint design: `test_no_sha_verifier_pattern.sh`

The lint detects three observable signatures of the dispatch-then-verify
pattern. All must be absent for the lint to pass:

1. **`head_sha` in an API call** — any workflow `run:` block containing the
   literal string `head_sha` (the verifier's API query key).
2. **`conclusion` inside a step named `*verify*`** — whole-file heuristic:
   a workflow file containing both the token `verify` and the token
   `conclusion` (covers the `"conclusion" == "success"` check).
3. **`commit_sha` as a `workflow_dispatch` input** — the sentinel that marks
   a workflow as a SHA-pinned dispatch target.

```bash
#!/usr/bin/env bash
# tests/unit/test_no_sha_verifier_pattern.sh
# Lint: no workflow may implement the dispatch-then-verify SHA-handshake.
# See SPEC-D3 and AGENTS.md §6.7.
set -uo pipefail
cd "$(dirname "$0")/../.."
. tests/lib/assert.sh
WORKFLOWS_DIR="${WORKFLOWS_DIR:-.github/workflows}"

# 1. head_sha in any workflow
hits=$(grep -rl "head_sha" "$WORKFLOWS_DIR" --include="*.yml" \
       --include="*.yaml" 2>/dev/null || true)
[ -z "$hits" ] \
  && _pass "no_head_sha_api_query" \
  || _fail "no_head_sha_api_query" "head_sha found in: $hits"

# 2. conclusion check inside a verify step (whole-file heuristic)
bad=""
for f in "$WORKFLOWS_DIR"/*.yml "$WORKFLOWS_DIR"/*.yaml; do
  [ -f "$f" ] || continue
  grep -qi "conclusion" "$f" && grep -qi "verify" "$f" && bad="$bad $f"
done
[ -z "$bad" ] \
  && _pass "no_conclusion_in_verify_step" \
  || _fail "no_conclusion_in_verify_step" "files match: $bad"

# 3. commit_sha dispatch input
hits=$(grep -rl "commit_sha" "$WORKFLOWS_DIR" --include="*.yml" \
       --include="*.yaml" 2>/dev/null || true)
[ -z "$hits" ] \
  && _pass "no_commit_sha_dispatch_input" \
  || _fail "no_commit_sha_dispatch_input" "commit_sha found in: $hits"

assert_summary
```

**False-positive handling.** Signature 2 is a whole-file heuristic. A
workflow with a step named "verify" that separately mentions "conclusion" in
a comment will falsely trigger. In the current ~15-file corpus no such case
exists. If one arises, tighten the predicate with `yq` before adding any
exclusion — never suppress blindly. Performance: pure `grep`, <0.1 s.

### 5.3 Fixture for lint meta-test

`tests/unit/fixtures/sha-verifier-lint/bad-verifier.yml` is a minimal
synthetic YAML containing all three bad signatures:

```yaml
# Adversarial fixture — triggers all three sha-verifier lint checks.
# NOT a real workflow. Used by test_no_sha_verifier_pattern.sh meta-test.
name: Bad verifier (fixture)
on:
  workflow_dispatch:
    inputs:
      commit_sha:
        description: "SHA to verify"
        required: false
jobs:
  verify:
    runs-on: ubuntu-24.04
    steps:
      - name: Verify green run on this commit
        run: |
          result=$(curl ... "?head_sha=$SHA")
          if echo "$result" | grep '"conclusion": "success"'; then exit 0; fi
          exit 1
```

The lint is run against this fixture directory in the §6 meta-test to
prove all three checks fire. The implementing agent MUST run the lint
against the pre-deletion corpus (with the real `chainsaw-verify.yml` still
present) and confirm non-zero exit before deleting the file.

### 5.4 SPEC-A4 dependency

This spec has a soft dependency on SPEC-A4 (PR-S.1 catch hook). Once
`chainsaw.yml` runs on push, CI failures will arrive without the agent
controlling timing. SPEC-A4's `catch:` block makes each failure self-
diagnosable inline. If SPEC-A4 has not landed, the implementing agent must
flag the gap in the PR description and keep the `scenario_filter` input as
a manual spot-check path.

---

## 6. Tests required

Per AGENTS.md §6.1 and §6.4.

| Layer | File | Assertion |
|---|---|---|
| Unit | `tests/unit/test_no_sha_verifier_pattern.sh` | All three signature checks pass against the real `.github/workflows/` corpus after deletion. Exit 0, three `PASS` lines. |
| Unit (meta-test) | Same script, `WORKFLOWS_DIR=tests/unit/fixtures/sha-verifier-lint` | Script exits non-zero, prints three `FAIL` lines — proves the lint detects the pattern and is not vacuously green. |
| Unit | Presence assertion in same script | `bad-verifier.yml` fixture exists and `chainsaw-verify.yml` is absent. Prevents accidental deletion of the adversarial fixture and confirms the target is gone. |

Adversarial review (§6.4): before committing the lint, dispatch a
`general-purpose` subagent with: facts shipped (1 deleted workflow, 1
modified trigger, 1 new lint + fixture), the §5.2 plan, failure-mode
(SHA-handshake re-emerging), non-goal "not testing the Actions API". Confirm
the three signatures are exhaustive and no current workflow falsely triggers
check 2.

---

## 7. Testing suggestions (unit / integration / e2e)

### Unit

1. **Clean-corpus pass.** `bash tests/unit/test_no_sha_verifier_pattern.sh`
   against the real `.github/workflows/`. Three `PASS` lines, exit 0.
2. **Fixture failure.** `WORKFLOWS_DIR=tests/unit/fixtures/sha-verifier-lint
   bash tests/unit/test_no_sha_verifier_pattern.sh` — non-zero exit, ≥1
   `FAIL` line per bad signature.
3. **Push-trigger present.** `grep -c "^  push:" .github/workflows/chainsaw.yml`
   returns 1.
4. **Verifier absent.** `! test -f .github/workflows/chainsaw-verify.yml`
   exits 0.
5. **`commit_sha` removed.** `grep -c "commit_sha" .github/workflows/chainsaw.yml`
   returns 0.

### Integration

Not applicable. The change is workflow YAML deletion and a static bash lint;
no runtime cluster or API dependency. The unit-level checks in §6 and §7-Unit
are sufficient.

### E2E

E2E coverage is manual observation of a live Actions run:

1. Push a no-op change touching `tests/chainsaw/versions.env` on a feature
   branch. Confirm `Chainsaw` appears in the push's checks; confirm `Chainsaw
   verify` does NOT appear.
2. Confirm the smoke scenario passes in the auto-triggered run — proves the
   push-trigger path is functionally equivalent to the old dispatch path.
3. Confirm the `Chainsaw` job in the Actions log no longer has a
   `commit_sha` input section in its run summary.

---

## 8. Documentation updates

- `/home/user/k8-platform/AGENTS.md` §6.7 — retire chainsaw from the
  heavy-CI-workflow contract; remove the four-step operating procedure for
  chainsaw; add a one-sentence citation of
  `tests/unit/test_no_sha_verifier_pattern.sh`.

- `/home/user/k8-platform/ai/testing-guidelines.md` — remove any reference
  to `chainsaw-verify.yml`; update chainsaw invocation guidance to
  `bash tests/chainsaw/run.sh` locally, `chainsaw.yml` push-triggered in CI.

---

## 9. Workflow / auto-invocation wiring

`test_no_sha_verifier_pattern.sh` follows the `test_*.sh` naming convention.
`tests/unit/run.sh` discovers it automatically via glob and
`.github/workflows/unit-tests.yml` executes `tests/unit/run.sh` on every
push. No edits to `run.sh` or `unit-tests.yml` required.

`chainsaw.yml` gains a `push` trigger (§5.1). After this spec lands,
qualifying pushes auto-trigger the harness; no manual dispatch is expected.

---

## 10. Discoverability

1. **Mechanical enforcement.** `test_no_sha_verifier_pattern.sh` runs on
   every push via `unit-tests.yml`. A PR reintroducing `head_sha`, a
   `conclusion`-in-verify step, or a `commit_sha` dispatch input fails the
   `Unit tests` check before merge.

2. **Documentation pointer.** Updated AGENTS.md §6.7 cites
   `test_no_sha_verifier_pattern.sh` and states the dispatch-then-verify
   pattern is retired for chainsaw. A future agent reading §6.7 lands on the
   lint and understands the constraint.

3. **Adversarial-review trigger.** Add to `ai/testing-guidelines.md` §6.4
   review checklist: *"For PRs touching workflow files, confirm no step
   queries the Actions API for a prior run's `head_sha` or `conclusion`,
   and no `workflow_dispatch` input is named `commit_sha`."* The reviewer
   subagent flags the pattern independent of the implementing agent's recall.

---

## 11. Verification checklist

- [ ] `test -f .github/workflows/chainsaw-verify.yml && echo PRESENT || echo ABSENT`
  — prints `ABSENT`.
- [ ] `grep -c "commit_sha" .github/workflows/chainsaw.yml`
  — returns `0`.
- [ ] `grep -c "^  push:" .github/workflows/chainsaw.yml`
  — returns `1`.
- [ ] `bash tests/unit/test_no_sha_verifier_pattern.sh`
  — exits 0, three `PASS` lines.
- [ ] `WORKFLOWS_DIR=tests/unit/fixtures/sha-verifier-lint bash tests/unit/test_no_sha_verifier_pattern.sh`
  — exits non-zero, at least one `FAIL` line.
- [ ] `bash tests/unit/run.sh 2>&1 | grep test_no_sha_verifier_pattern`
  — appears in output (auto-discovery confirmed).
- [ ] `grep "chainsaw-verify" AGENTS.md`
  — no matches.
- [ ] `grep "chainsaw-verify" ai/testing-guidelines.md`
  — no matches.
- [ ] Push a no-op commit to a feature branch touching `tests/chainsaw/`.
  Confirm `Chainsaw` fires in Actions; confirm `Chainsaw verify` does not.

---

## 12. Rollout notes

- **Backward compat.** Deleting `chainsaw-verify.yml` removes a PR-gate
  check. Open PRs blocked on `Chainsaw verify` become unblocked automatically;
  the check was a synthetic gate, not a test. No test coverage is lost.

- **Audit-before-merge.** Author `test_no_sha_verifier_pattern.sh` BEFORE
  deleting `chainsaw-verify.yml`. Run the lint against the pre-deletion corpus
  and confirm non-zero exit (the real file's `head_sha` usage and `commit_sha`
  input trigger two signatures). This proves the lint would have caught the
  original file.

- **SPEC-A4 sequencing.** Land SPEC-A4 before or alongside this spec. Once
  `chainsaw.yml` runs on push, red CI runs must be self-diagnosable. See §5.4.

- **In-flight branches.** Rebase on main after merge; rely on auto-triggered
  `chainsaw.yml`. No code conflict.

- **Pluralsight sandbox constraints** not relevant. Workflow YAML deletion and
  a bash lint; no cloud resources touched.

- **Branch sequencing.** Standalone `chore/delete-chainsaw-verify` or bundled
  with other Tier D items (D1, D2, D4, D5). If bundled, run each §11 checklist
  independently so rollback blast radii remain separable.

---

## 13. Estimated effort

**S** — small (≤1 hour).

- **Authoring** (~15 min): delete `chainsaw-verify.yml`, edit `chainsaw.yml`
  trigger, author `test_no_sha_verifier_pattern.sh` (~50 lines), create
  `bad-verifier.yml` fixture.
- **Rollout audit** (~15 min): run lint against pre- and post-deletion corpus;
  run `tests/unit/run.sh`; update AGENTS.md §6.7 and `testing-guidelines.md`.
- **Review + smoke** (~20 min): step through §11 checklist; push no-op commit
  and confirm push-trigger fires in Actions without `Chainsaw verify`.

Dominant uncertainty: SPEC-A4 sequencing (§5.4); budget +15 min if unmerged.
