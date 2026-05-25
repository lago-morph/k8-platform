# SPEC-A2 — crossplane-claim-verify: decision tree naming the gap

## 1. Summary

Extend the `crossplane-claim-verify` skill so that after walking the
claim → XR → MR chain (SPEC-A1's job), it classifies a non-Ready
outcome into one of four named failure classes — composition function
never produced MRs, an MR is stuck not-Ready, all MRs Ready but the XR
isn't, or IRSA AssumeRoleWithWebIdentity rejection — and emits a
single line that names the gap and points at the exact next read. The
goal is to kill the "we have a 170 KB log dump and don't know what to
look at" failure mode the late-2026-05-24 session hit when the XR had
zero `status.conditions`.

## 2. Retro pain killed (with cited PRs/bugs)

- **Primary pain — `ai/handoff.md` ~line 95** (Step 7 of QUICKSTART):
  *"the XR had zero `status.conditions` and the composed managed
  resources were NotFound. The composition reconciler isn't producing
  the MR objects at all — `XR.spec.resourceRefs` is populated but the
  MRs themselves don't exist."* The session had no procedure for
  naming this class — it spent debug cycles re-confirming the symptom
  on diagnose run [26355033199](https://github.com/lago-morph/k8-platform/actions/runs/26355033199)
  before forming a hypothesis. The decision tree gives that class a
  name ("v2.0.1 zero-conditions / composite-reconciler") and a fixed
  next read.
- **PR #66** — IRSA SA-name pinning bug. The provider was using a
  hash-suffixed SA whose `sub` claim didn't match the IRSA trust. The
  symptom at claim level was "MR never reconciles, no clear reason".
  Decision-tree class (d) makes this a one-line surfacing rather than
  a multi-hop investigation.
- **PR #67** — `triggers_replace` miss; the apply was a no-op so the
  cluster never saw the fix. Not directly an XR symptom, but the
  skill's decision tree surfaces it indirectly: when class (b) keeps
  recurring across attempts with identical MR-conditions output, the
  skill recommends checking whether the last apply actually rolled
  the relevant object (handoff.md §"Behavioral rule additions").
- **PR #61 bug 4** — Composition string-transform missing `type:
  Format`. Symptom: `resourceRefs` populated but MRs absent —
  composition function rejected input. Class (a) of the tree, with
  the explicit instruction to dump function-pod logs filtered to the
  XR name (the thing that would have surfaced this in PR #61 in
  minutes instead of hours).

## 3. Out of scope

- The walk itself (claim → XR → MR list and their conditions). That
  is SPEC-A1's responsibility; SPEC-A2 consumes the walk's output.
- Automated remediation. The skill names the gap and points at the
  next read; the agent (or operator) decides the fix.
- Crossplane 2.2 upgrade evaluation (handoff Pending follow-up #8).
  The decision tree's class (c) entry mentions v2.0.1 as the likely
  cause but does not gate on the upgrade.
- Cluster-scoped diagnostics not driven by a specific claim (e.g.
  "is the provider healthy in general?"). The skill stays
  claim-anchored.
- New chainsaw scenarios. Tests for the new logic live in
  `tests/unit/` against a fixture corpus — see §6.

## 4. Files to change / create

Modify:

- `.claude/skills/crossplane-claim-verify/SKILL.md` — insert a new
  **Phase 4b — Classify the gap** section between the existing Phase
  3 (descend) and Phase 4 (cloud verification). Reference the new
  decision-tree doc.

Create:

- `.claude/skills/crossplane-claim-verify/reference/decision-tree.md`
  — the four classes, each with: detector predicate (which jsonpath
  outputs trigger this class), the one-line gap-naming message
  template, the exact next read the agent runs, and the most-likely
  root-cause family with file pointer.
- `.claude/skills/crossplane-claim-verify/reference/fixtures/`
  directory containing one captured-YAML fixture per class:
  - `class-a-empty-resourcerefs.yaml`
  - `class-b-mr-not-ready.yaml`
  - `class-c-all-mrs-ready-xr-not.yaml`
  - `class-d-irsa-rejection.yaml`
  Each is a real or synthesized `kubectl get -o yaml` dump
  (sanitized — no account IDs per AGENTS.md §8.1) for the relevant
  object(s), used as test input.
- `tests/unit/test_claim_decision_tree.sh` — unit harness that pipes
  each fixture through the classifier and asserts the expected class
  + gap message. Wired into `tests/unit/run.sh`.

## 5. Implementation notes

The classifier is a pure function of three inputs the SPEC-A1 walker
already collects:

1. `xr.spec.resourceRefs` (list, may be empty)
2. For each MR ref: its `.status.conditions` (Synced, Ready, plus
   reason)
3. The XR's own `.status.conditions` (may be empty — the v2.0.1
   bug class)

Pseudocode for `classify(walk_output) -> (class, gap_message, next_read)`:

```
if walk_output.xr.resourceRefs is empty:
    class = "A"
    gap = "Composition function never produced managed resources for XR <name>."
    next_read = "kubectl -n crossplane-system logs deploy/function-patch-and-transform-* --tail=500 | grep <xr-uid>"
    return

failing_mrs = [m for m in walk_output.mrs if not condition(m,"Ready").status=="True"]
if failing_mrs:
    class = "B"
    first = failing_mrs[0]
    cond = first_false_condition(first)
    gap = f"MR {first.kind}/{first.name} is not Ready: {cond.type}={cond.status} reason={cond.reason} message={cond.message[:200]}"
    if cond.message contains "AssumeRoleWithWebIdentity" or cond.reason contains "InvalidIdentityToken":
        class = "D"
        next_read = irsa_check_commands(provider_sa(first))
    else:
        next_read = f"kubectl describe {first.kind}/{first.name}; aws <service> describe-* ..."
    return

if walk_output.xr.conditions is empty or no Ready in xr.conditions:
    class = "C"
    gap = "All composed MRs are Ready=True but XR <name> has no Ready condition. Likely Crossplane v2.0.1 composite reconciler not emitting XR status — see handoff §8 (2.2 upgrade)."
    next_read = "kubectl -n crossplane-system logs deploy/crossplane --since=10m | grep <xr-name>; kubectl get composite <xr-name> -o yaml"
    return

ready_cond = condition(walk_output.xr, "Ready")
if ready_cond.status != "True":
    class = "C"
    gap = f"XR has Ready={ready_cond.status} reason={ready_cond.reason} message={ready_cond.message[:200]}"
    next_read = "kubectl describe <xr-kind>/<xr-name>"
    return

# else: nothing to classify — claim was actually Ready, walker should not have called us
```

For class (D) the next_read assembles four commands:

```
aws sts get-caller-identity
aws iam get-role --role-name <derived-from-providerconfig> --query Role.AssumeRolePolicyDocument.Statement[*].Condition
kubectl -n crossplane-system get sa <sa-name> -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'
kubectl -n crossplane-system get deploy -l pkg.crossplane.io/provider=<provider> -o jsonpath='{.items[0].spec.template.spec.serviceAccountName}'
```

The last command is the PR #68 lesson: serviceAccountName on the
running Deployment must match the IRSA trust subject; the SA the
DeploymentRuntimeConfig says to use is not necessarily the SA the
Deployment actually mounts.

Classifier lives as a bash function in the SKILL.md procedure (no
new code in `scripts/`). Inputs are captured by the walker into
temp files; the classifier reads them with `kubectl ... -o
jsonpath` or `yq`. Keep it shell-only so it runs anywhere the
skill runs.

## 6. Tests required

Per AGENTS.md §6.1, layer + file + assertion shape:

| Layer | File | Assertion shape |
|---|---|---|
| Unit | `tests/unit/test_claim_decision_tree.sh` | For each of the 4 fixtures in `.claude/skills/crossplane-claim-verify/reference/fixtures/`, run the classifier function (sourced from SKILL.md or extracted into a small `classify.sh` callable), capture stdout, assert (a) the printed `CLASS=<A|B|C|D>` matches the fixture's expected class, (b) the gap message contains the fixture's expected substring (e.g. fixture C's output contains `"no Ready condition"`), (c) the next_read line contains the expected command (e.g. fixture A contains `"function-patch-and-transform"`). |
| Unit | `tests/unit/test_claim_decision_tree.sh` (same file) | Negative test: a synthetic "all-green" fixture must cause the classifier to print `CLASS=NONE` and exit non-zero — guarantees the skill never silently classifies a healthy claim as broken. |
| Unit | `tests/unit/test_claim_decision_tree.sh` (same file) | Fixture C with non-empty `xr.status.conditions` but `Ready=False` must classify as C with the specific Ready-reason in the gap line — distinguishes the v2.0.1 zero-conditions sub-class from "ordinary" XR-not-Ready. |
| Unit | `tests/unit/test_claim_decision_tree.sh` (same file) | Fixture B with the MR message string `"AssumeRoleWithWebIdentity ... 403"` must classify as D, not B — verifies the class-D override path. |

No new chainsaw, integration, or Kyverno layer needed — the
classifier has no cluster-side runtime contract; it's a text
transformer over walker output. The IRSA/SA-name contract it
detects is already covered by `tests/unit/test_irsa_helm_linkage.sh`
and PR #66's manifest-pin assertion.

§6.4 adversarial-reviewer-of-test-plans: before authoring the test
file, dispatch one subagent with the brief — fixtures are the
load-bearing surface; if a fixture doesn't match a real
walker-output shape, the test green-lights a classifier that won't
work in production.

## 7. Testing suggestions (unit / integration / e2e)

**Unit** (`tests/unit/test_claim_decision_tree.sh`)

1. Pipe `class-a-empty-resourcerefs.yaml` through the classifier; assert stdout contains `CLASS=A` and the phrase `function-patch-and-transform`.
2. Pipe `class-b-mr-not-ready.yaml`; assert `CLASS=B` and the MR name appears in the gap line.
3. Pipe `class-c-all-mrs-ready-xr-not.yaml`; assert `CLASS=C` and the phrase `no Ready condition`.
4. Pipe `class-d-irsa-rejection.yaml` (message contains `AssumeRoleWithWebIdentity`); assert `CLASS=D` and `irsa_check_commands` output references the provider SA.
5. Pipe a synthetic all-green fixture; assert `CLASS=NONE` and a non-zero exit code — guarantees the classifier never fires on a healthy claim.

**Integration** — not applicable for this spec. The classifier is a pure text transformer over walker-collected YAML; it has no cluster-side runtime contract, no API calls, and no state. The IRSA/SA-name contract it detects is already exercised by `tests/unit/test_irsa_helm_linkage.sh` and the PR #66 manifest-pin assertion. Adding an integration layer would require a live cluster running a deliberately-broken Composition, which is covered instead by the §6 manual smoke check.

**E2E** (`tests/unit/run.sh` orchestrates; no chainsaw scenario added by this spec)

1. Run `bash tests/unit/run.sh`; assert the `test_claim_decision_tree.sh` entry appears in output and the suite exits 0 — proves the new unit file is wired into the runner.
2. Apply a PlatformSecret claim backed by an intentionally empty `resources:` Composition on a kind cluster; invoke `crossplane-claim-verify`; assert the final output line is `CLASS=A` and references function-pod logs. This can be deferred until the SPEC-A1 walker exists and a kind cluster is available; it is not a gate for this spec's merge.

## 8. Documentation updates

- `.claude/skills/crossplane-claim-verify/SKILL.md` — insert Phase
  4b as described in §4. Update the "Companion skill" section to
  note that SPEC-A1 (walker) and SPEC-A2 (classifier) are
  complementary phases of the same skill.
- `.claude/skills/crossplane-claim-verify/reference/failure-taxonomy.md`
  — cross-link each taxonomy entry to the decision-tree class it
  belongs to (A/B/C/D), so the agent can jump from "I got class C"
  → the taxonomy entry for v2.0.1 reconciler issues.
- `ai/handoff.md` — when this spec lands, add a line under
  "Behavioral rule additions" pointing at the new decision tree:
  *"After every `crossplane-claim-verify` invocation that doesn't
  go green, the skill prints `CLASS=<A|B|C|D>` and a one-line gap
  message — read that before scrolling logs."*
- No edits to `AGENTS.md` — §7 already names this skill; the new
  internal phase is an implementation detail.

## 9. Workflow / auto-invocation wiring

AGENTS.md §7 already says: *"After applying a Crossplane Claim,
XRD, or Composition (whether via kubectl, ArgoCD sync, or CI),
invoke the crossplane-claim-verify skill."* The new Phase 4b runs
inside that same invocation — no change to the trigger. The skill
remains auto-invoked on the same set of conditions; the
classification fires unconditionally on any non-Ready outcome.

Specifically: SPEC-A1's walker runs Phases 1–3, then if the claim
is not Ready=True, SPEC-A2's classifier runs as Phase 4b *before*
the skill exits to the inner-loop. The classifier output (one
`CLASS=` line + one gap line + one next_read line) is the last
thing printed before the skill returns control to the agent. The
agent then decides whether to retry, fix, or escalate — same
three-strike envelope as today (Phase 7 in SKILL.md).

No new workflow files, no new dispatch path. The classifier is
pure-local — runs anywhere `kubectl` + `yq` are available
(handoff §"Session capabilities" confirms both are present in the
current sandbox).

## 10. Discoverability for future agents

Three forcing functions:

1. **SKILL.md Phase 4b is unconditional** — the skill cannot reach
   its "claim not Ready, returning to agent" path without printing
   the `CLASS=` line. A future agent reading the skill's procedure
   sees the classifier as a required step, not an optional
   reference.
2. **`reference/decision-tree.md` is named in the failure-taxonomy
   cross-links.** When the agent reads `failure-taxonomy.md`
   (which it must — Phase 6 of SKILL.md points at it), every entry
   says "this is class X — see decision-tree.md". The agent cannot
   pick a taxonomy entry without seeing the class label.
3. **The unit test enforces the classifier output shape.** If a
   future refactor drops the `CLASS=` line or renames a class, the
   test fails. The test name (`test_claim_decision_tree.sh`)
   shows up in `tests/unit/run.sh` output every push, keeping the
   contract visible.

## 11. Verification checklist

Concrete observable checks the agent runs after implementing this
spec:

- [ ] `bash tests/unit/test_claim_decision_tree.sh` exits 0 with
  one `PASS` line per fixture (4 positive + 2 negative/override = 6
  assertions).
- [ ] `bash tests/unit/run.sh` includes the new test in its output
  and exits 0.
- [ ] `grep -c "Phase 4b" .claude/skills/crossplane-claim-verify/SKILL.md`
  returns ≥ 1.
- [ ] `ls .claude/skills/crossplane-claim-verify/reference/fixtures/`
  returns exactly 4 files matching `class-[abcd]-*.yaml`.
- [ ] Each entry in
  `.claude/skills/crossplane-claim-verify/reference/failure-taxonomy.md`
  contains a `(class A|B|C|D)` label.
- [ ] Manual smoke: apply a PlatformSecret claim against an
  intentionally-broken Composition (e.g. one with empty
  `resources:`), run the skill, confirm the printed line says
  `CLASS=A` and names function-pod logs as the next read.
- [ ] Manual smoke against the live cluster (post phase-1 bring-up,
  see handoff Step 5): apply a healthy probe claim, confirm the
  skill reaches Phase 5 (success) without ever printing a `CLASS=`
  line — the classifier only fires on failure.

## 12. Rollout notes

- Land on branch `feat/claim-decision-tree` stacked off the SPEC-A1
  branch (the walker must exist before the classifier consumes its
  output). Per AGENTS.md §3 Stacked PRs.
- No Terraform changes, no cluster changes, no destruction. Safe to
  land at any phase state.
- No account-derived values per AGENTS.md §8.1 — fixtures use
  placeholders (`<account-id>`, `<region>`) and the classifier
  treats account-derived strings as opaque tokens.
- Backward compatible — agents using the skill today see one extra
  line of output on failure paths and no change on success paths.
- After landing, the next session that hits an XR-not-Ready
  outcome should produce a one-line root-cause hint instead of a
  multi-hop investigation. If it doesn't, the fixture set is
  incomplete — add the new shape and re-run §6's tests.

## 13. Estimated effort

**S** — small.

Justification: pure-local shell logic over already-collected walker
output; four fixture files and one bash test; SKILL.md insertion is
~30 lines; decision-tree.md is ~80 lines (four class entries with
the same structure). No Terraform, no cluster work, no new
workflows. The walker (SPEC-A1) is the load-bearing prerequisite;
once that exists, the classifier is a half-day of authoring plus
adversarial-review and a fixture-collection pass against the
live cluster's actual `kubectl get -o yaml` shape. Total: ~4–6
hours of focused work.
