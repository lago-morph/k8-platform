# SPEC-LB7 — UID-shadowing integration test (cross-namespace ASM key collision)

Brainstorm ID: A3-031. Tier B, item B7. Pairs with static lint A1→A3-012.

## 1. Summary

This spec adds a dedicated integration test that creates two `PlatformSecret`
claims with the **same `metadata.name`** in **two different namespaces** and
asserts the resulting ASM secrets have **distinct keys** — one per XR UID —
and do not overwrite each other. The test lives at
`tests/integration/12_uid_shadowing_collision.sh` and exercises the live
management cluster, mirroring the structure of the existing
`tests/integration/11_platform_secret_e2e.sh`. It is the runtime counterpart
to the static lint described in brainstorm comment A1→A3-012 (which asserts at
PR time that every ASM-writing Composition's external-name template includes
`${xr.metadata.uid}`). Both defences are necessary: the lint fires at authoring
time without a cluster; this test fires against the live cluster and catches
Composition regressions that slip past the lint. Part of the Tier B regression-
corpus group in `ai/brainstorming/specs/larger-list-preferences.md` (B7).

## 2. Retro pain killed

- **PR #59 — bash `$UID` shadowing, ASM key collision.**
  `retrospective/2026-05-24-62.md` §Phase 5: every claim's integration test
  used `UID=$(kubectl get ...)`, which silently failed because `$UID` is a bash
  readonly builtin (process user-id, = 1001 on Actions runners). All downstream
  `ASM_KEY="k8-platform/${UID}"` became `k8-platform/1001`, meaning every claim
  in the test run targeted the same ASM secret. The Composition was already
  correct; no test directly verified that two same-named claims in different
  namespaces produce two *distinct* ASM keys.

- **Silent PASS on claim verification.** Same retro §Phase 5: `11_platform_secret_e2e.sh`
  reported `PASS: PlatformSecret end-to-end` while four `gave up after 183s`
  lines appeared earlier in the same log. A dedicated two-claim collision test
  makes ASM-key uniqueness a first-class assertion rather than an implicit
  side-effect of a single-claim happy-path.

- **Composition comment is load-bearing but untested.**
  `crossplane/compositions/platform-secret.yaml` lines 7–9 state: *"Named
  `k8-platform/<XR-uid>` so two claims with the same name in different
  namespaces don't collide on the ASM key."* No automated check enforces this
  property on the live cluster. Any Composition edit that replaces `metadata.uid`
  with `spec.claimRef.name` passes every existing test undetected.

- **Negative-path coverage absent.** `retrospective/2026-05-24-62.md` §Phase 6:
  Bug 4 was invisible because existing scenarios only asserted "the MR exists"
  and "the claim reaches Ready=True". The same blind spot applies here — no
  existing scenario asserts two separate claims produce two separate ASM secrets.

## 3. Out of scope

- **Static lint asserting `${xr.metadata.uid}` in every ASM-writing
  Composition.** That is brainstorm item A1→A3-012 — a separate future PR.
  This spec is the runtime integration test only. The lint catches a regression
  at PR authoring time; this test catches one on the live cluster. They are
  layered defences, not alternatives. Neither replaces the other.

- **Chainsaw equivalent in a kind cluster.** A kind-cluster version falls in
  SPEC-C4's scope (chainsaw golden-file pattern). Defer to a follow-on PR that
  stacks on SPEC-C4, which is responsible for the `expected/` fixture layout.

- **Soak / slow-collision variant.** Brainstorm comment A2→A3-004 proposes a
  30-minute loop. That is a distinct follow-on; the present spec targets a
  single deterministic collision assertion with two claims applied serially.

- **Parallel-subagent multi-claim variant.** Brainstorm comment A5→A3-007. A
  serial two-claim test is sufficient to catch the structural collision class
  and is simpler to diagnose when it fails.

### Considered and rejected

- **Kind-only render-level assertion.** A kind test can assert two rendered MRs
  have different `spec.forProvider.name` values cheaply, but it does not catch
  `ExternalSecret.spec.dataFrom[0].extract.key` misconfiguration (the ESO side
  must also reference the correct UID-derived key). Decided: keep the test on
  the live cluster where both ASM creation and ESO extraction are verified
  end-to-end. The kind variant can be added later under SPEC-C4.

- **Extending `11_platform_secret_e2e.sh`.** Appending a second claim to the
  existing test makes UID-collision failures harder to diagnose — the failure
  message appears next to unrelated rotation and deletion assertions. A
  dedicated script with a single named concern is more maintainable.

## 4. Files to change / create

### Create

| Path | Purpose |
|---|---|
| `/home/user/k8-platform/tests/integration/12_uid_shadowing_collision.sh` | New integration test |
| `/home/user/k8-platform/tests/unit/test_uid_shadowing_guard_fires.sh` | TDD fixture: pre-fix Composition renders colliding names |
| `/home/user/k8-platform/tests/unit/test_composition_uid_patch_present.sh` | Lint: Composition still uses `metadata.uid` patch |
| `/home/user/k8-platform/tests/fixtures/compositions/platform-secret-pre-uid-fix.yaml` | Frozen pre-fix Composition for the TDD unit test |

### Modify

| Path | What changes |
|---|---|
| `/home/user/k8-platform/tests/integration/README.md` | Add row for `12_uid_shadowing_collision.sh` |
| `/home/user/k8-platform/ai/testing-guidelines.md` | Add bug-class traceability row (PR #59 / UID-shadowing) |
| `/home/user/k8-platform/ai/TESTING-PLAN.md` | Append UID-shadowing entry to bug-to-test matrix |
| `/home/user/k8-platform/AGENTS.md` | One cross-link sentence under §6 |

## 5. Implementation notes

### Test scenario

```
ns-a / my-secret  →  XR uid-A  →  ASM key k8-platform/<uid-A>
ns-b / my-secret  →  XR uid-B  →  ASM key k8-platform/<uid-B>

assert: uid-A != uid-B
assert: ASM secret k8-platform/<uid-A> exists in AWS
assert: ASM secret k8-platform/<uid-B> exists in AWS
assert: ARN of uid-A != ARN of uid-B  (independent objects)
```

### Script skeleton (body of `12_uid_shadowing_collision.sh`)

```bash
#!/usr/bin/env bash
# 12: UID-shadowing collision guard.
# Defends: PR #59 root cause. Pairs with static lint A1->A3-012.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-lib.sh"

require_kube
require_aws

if ! kubectl get crd platformsecrets.platform.k8-platform.io >/dev/null 2>&1; then
  skip "PlatformSecret CRD not present (phase 2 not synced yet?)"
fi
if ! kubectl get clustersecretstore aws-secrets-manager \
     -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null \
     | grep -q True; then
  skip "ClusterSecretStore aws-secrets-manager not Ready"
fi

CLAIM_NAME="uid-shadow-${RUN_ID}"
NS_A="uid-shadow-a-${RUN_ID}"
NS_B="uid-shadow-b-${RUN_ID}"
REGION="${AWS_REGION:-us-east-1}"

trace kubectl create ns "$NS_A"
trace kubectl create ns "$NS_B"
add_cleanup "kubectl delete platformsecret -n $NS_A $CLAIM_NAME --wait=true --timeout=120s || true"
add_cleanup "kubectl delete platformsecret -n $NS_B $CLAIM_NAME --wait=true --timeout=120s || true"
add_cleanup "kubectl delete ns $NS_A --wait=false || true"
add_cleanup "kubectl delete ns $NS_B --wait=false || true"

for NS in "$NS_A" "$NS_B"; do
  cat <<YAML | trace kubectl apply -f -
apiVersion: platform.k8-platform.io/v1alpha1
kind: PlatformSecret
metadata:
  name: ${CLAIM_NAME}
  namespace: ${NS}
  labels:
    test.k8-platform/integration: "true"
spec:
  refreshInterval: 1h
  region: ${REGION}
  description: "uid-shadow collision test ns=${NS}"
YAML
done

for NS in "$NS_A" "$NS_B"; do
  wait_for "PlatformSecret/${CLAIM_NAME} Ready=True in ${NS}" 180 5 -- \
    bash -c "kubectl get platformsecret -n ${NS} ${CLAIM_NAME} \
             -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' \
             2>/dev/null | grep -q True"
done

# NB: variable names XR_UID_A / XR_UID_B avoid $UID (bash readonly).
# See PR #59 post-mortem in retrospective/2026-05-24-62.md §Phase 5.
xr_a=$(kubectl get platformsecret -n "$NS_A" "$CLAIM_NAME" \
         -o jsonpath='{.spec.resourceRef.name}')
xr_b=$(kubectl get platformsecret -n "$NS_B" "$CLAIM_NAME" \
         -o jsonpath='{.spec.resourceRef.name}')
XR_UID_A=$(kubectl get xplatformsecret "$xr_a" -o jsonpath='{.metadata.uid}')
XR_UID_B=$(kubectl get xplatformsecret "$xr_b" -o jsonpath='{.metadata.uid}')
[ -n "$XR_UID_A" ] || ng "could not read uid of XR $xr_a"
[ -n "$XR_UID_B" ] || ng "could not read uid of XR $xr_b"

[ "$XR_UID_A" != "$XR_UID_B" ] \
  || ng "BUG: both claims share XR UID $XR_UID_A — UID-shadowing regression"
ok "XR UIDs are distinct"

ASM_KEY_A="k8-platform/${XR_UID_A}"
ASM_KEY_B="k8-platform/${XR_UID_B}"
wait_for "ASM $ASM_KEY_A exists" 60 5 -- \
  bash -c "aws secretsmanager describe-secret --secret-id '${ASM_KEY_A}' --region '${REGION}' >/dev/null 2>&1"
wait_for "ASM $ASM_KEY_B exists" 60 5 -- \
  bash -c "aws secretsmanager describe-secret --secret-id '${ASM_KEY_B}' --region '${REGION}' >/dev/null 2>&1"

ARN_A=$(aws secretsmanager describe-secret --secret-id "$ASM_KEY_A" \
          --region "$REGION" --query 'ARN' --output text)
ARN_B=$(aws secretsmanager describe-secret --secret-id "$ASM_KEY_B" \
          --region "$REGION" --query 'ARN' --output text)
[ "$ARN_A" != "$ARN_B" ] \
  || ng "BUG: both ASM keys resolve to the same ARN ($ARN_A) — collision"

ok "ARN_A ($ARN_A) != ARN_B ($ARN_B): no collision"
ok "UID-shadowing collision guard: PASS"
```

### Variable naming discipline

The implementing agent MUST NOT use `UID=` anywhere in the file. The
pre-existing lint `tests/unit/test_shell_readonly_var_assignment.sh` (PR #59)
will catch a regression if the restricted name reappears in a future edit.

### Cleanup ordering

`add_cleanup` calls register in LIFO order. Claims are deleted before
namespaces so the claim finalizer can drive ASM teardown. Per-claim timeout
(120 s) is consistent with `11_platform_secret_e2e.sh`.

### TDD fixture (`test_uid_shadowing_guard_fires.sh`)

The fixture copies the pre-fix Composition (ASM name derived from
`spec.claimRef.name` instead of `metadata.uid`), runs `crossplane render`
against two claim fixtures with the same name in different namespaces, and
asserts the two rendered MR `spec.forProvider.name` values are **equal** —
proving that the pre-fix shape would collide and that `12` would fire non-zero
in that scenario. This is the red-first TDD step.

### Performance

Two serial claims, two 180 s wait loops, four AWS API calls. Typical wall-clock
on a healthy cluster: 60–90 s. The wait loops dominate; shortening them risks
false negatives on slow provider reconciliation.

## 6. Tests required

| Layer | File | Assertion |
|---|---|---|
| Integration | `tests/integration/12_uid_shadowing_collision.sh` | Two same-named claims in different namespaces produce distinct ASM keys and ARNs |
| Unit (TDD fixture) | `tests/unit/test_uid_shadowing_guard_fires.sh` | Pre-fix Composition renders equal `spec.forProvider.name` for both claims; confirms the integration test would fail |
| Unit (composition lint) | `tests/unit/test_composition_uid_patch_present.sh` | `yq` asserts `metadata.uid` appears as the `fromFieldPath` for the `spec.forProvider.name` patch |
| Unit (existing, extend) | `tests/unit/test_shell_readonly_var_assignment.sh` | Scan glob includes `12_uid_shadowing_collision.sh`; no `UID=` found |

## 7. Testing suggestions (unit / integration / e2e)

Distinct from §6 (gate); this is the broader follow-on catalogue.

**Unit** — fast, no cluster (<10 s each):

1. `tests/unit/test_uid_shadowing_guard_fires.sh` — TDD fixture (described in
   §5). Asserts the pre-fix Composition produces a collision; verifies the guard
   is effective.
2. `tests/unit/test_composition_uid_patch_present.sh` — `yq` one-liner confirming
   the `metadata.uid` → `spec.forProvider.name` patch is present. Static defence
   while A1→A3-012 (the broader lint) remains unimplemented.
3. Extend `test_shell_readonly_var_assignment.sh` glob coverage assertion to
   confirm `12_uid_shadowing_collision.sh` is included.

**Integration** — live cluster (60–180 s each):

1. `12_uid_shadowing_collision.sh` (the gate test). Two namespaces, one claim
   each, distinct ASM keys and ARNs asserted.
2. Three-namespace variant (extend `12` or add `12b`): third claim in third
   namespace. Defends against hypothetical (ns, name)-hash collisions at N=3.
3. Soak companion (`SOAK_ITERATIONS=10` env var): create/delete the same pair
   10 times; assert no collision on any iteration. Addresses A2→A3-004.

**E2E** — chainsaw against kind cluster (minutes; workflow_dispatch only):

1. `tests/chainsaw/platform-secret/03-cross-namespace-uid-isolation/` — Apply
   two claims (same name, `default` and `test-secondary` namespaces). Assert
   two `Secret` MRs exist with non-equal `spec.forProvider.name`. Does not
   require live AWS — rendered MR spec is sufficient.
2. When SPEC-C4 is in place, add golden files `expected/asm-secret-a.yaml` and
   `expected/asm-secret-b.yaml` asserting distinct `spec.forProvider.name`.

The E2E layer has distinct value from the integration layer: it catches a
Composition regression without a live AWS account, enabling PR-time verification
on every chainsaw dispatch. Both layers are worth having.

## 8. Documentation updates

- **`AGENTS.md` §6** — Add: "The UID-shadowing collision class (PR #59) is
  defended at runtime by `tests/integration/12_uid_shadowing_collision.sh` —
  see `ai/brainstorming/specs/SPEC-LB7-uid-shadowing-test.md`."
- **`ai/testing-guidelines.md`** — Add bug-class row: "Bug 5 / PR #59 — bash
  `$UID` shadowing → `test_shell_readonly_var_assignment.sh` (authoring) +
  `12_uid_shadowing_collision.sh` (runtime)."
- **`ai/TESTING-PLAN.md`** — Append UID-shadowing entry to the bug-to-test matrix.
- **`tests/integration/README.md`** — Add row for `12_uid_shadowing_collision.sh`.

## 9. Workflow / auto-invocation wiring

`12_uid_shadowing_collision.sh` is auto-discovered by
`.github/workflows/integration-tests.yml` via `test_filter=12` and
`test_filter=all` dispatch modes. The existing `tests/integration/**` path
filter covers the new file. No new workflow file is required.

Unit tests are auto-discovered by `tests/unit/run.sh` via its `test_*.sh` glob.
No additional wiring is needed.

## 10. Discoverability

1. **Mechanical enforcement** — `tests/unit/test_composition_uid_patch_present.sh`
   fails CI if a Composition PR removes the `metadata.uid` patch from
   `spec.forProvider.name`. `test_shell_readonly_var_assignment.sh` fails CI if
   `UID=` reappears in any integration script. Both name the violated contract
   in their failure messages.

2. **Documentation pointer** — `AGENTS.md` §6 (after §8 update) carries the
   cross-link. An agent reading §6 for test discipline lands here. The
   `ai/testing-guidelines.md` bug-class row points at both the unit guard and
   this integration test.

3. **Adversarial-review trigger** — Per AGENTS.md §6.4: any PR modifying
   `crossplane/compositions/platform-secret.yaml` or adding a new ASM-writing
   Composition must include in the adversarial-reviewer brief: "Does the
   external-name template derive from `metadata.uid`? Could two same-named
   claims in different namespaces collide on the ASM key?"

## 11. Verification checklist

- [ ] `bash -n tests/integration/12_uid_shadowing_collision.sh` exits 0
- [ ] `grep -n '\bUID=' tests/integration/12_uid_shadowing_collision.sh` returns empty
- [ ] `grep -c 'XR_UID_[AB]' tests/integration/12_uid_shadowing_collision.sh` returns ≥ 4
- [ ] `bash tests/unit/test_uid_shadowing_guard_fires.sh` exits non-zero (guard fires on pre-fix Composition)
- [ ] `bash tests/unit/test_composition_uid_patch_present.sh` exits 0 on current Composition
- [ ] `grep 'uid_shadow\|uid-shadow' tests/integration/README.md` returns a match
- [ ] `grep 'uid_shadow\|12_uid' ai/testing-guidelines.md` returns a match
- [ ] `grep 'SPEC-LB7' AGENTS.md` returns a match
- [ ] `integration-tests.yml` dispatched with `test_filter=12` concludes green on a live cluster
- [ ] Cleanup path verified: both ASM secrets gone after test teardown (`aws secretsmanager describe-secret` returns `ResourceNotFoundException` for both keys)

## 12. Rollout notes

**Backward compatibility.** The new test file and unit scripts are purely
additive. Documentation edits are one-line additions. No existing test is
modified except extending the scan glob in `test_shell_readonly_var_assignment.sh`.

**Audit-before-merge.** Run `tests/unit/run.sh` locally before opening the PR.
Both new unit tests must be green; `test_uid_shadowing_guard_fires.sh` must exit
non-zero against the fixture.

**Sandbox constraints.** Two PlatformSecret claims = two ASM secrets.
`recoveryWindowInDays: 0` in the Composition means immediate deletion on
teardown; no 7-day window blocks re-runs. The `us-east-1` / `us-west-2`
constraint in `ai/testing-guidelines.md` is respected via `$AWS_REGION`.
EC2 and instance-type constraints do not apply.

**Branch sequencing.** Independent of SPEC-C4, SPEC-B2, SPEC-B6. No upstream
dependency. The SPEC-C4 chainsaw scenario (§7 E2E item 1) can be added in the
same PR if SPEC-C4 has already landed, or deferred to a follow-on.

## 13. Estimated effort

**S** (≤1 hour):

- `12_uid_shadowing_collision.sh` (~20 min): structurally identical to `11`;
  copy, add two-namespace loop and UID-comparison assertions.
- Unit tests (`test_uid_shadowing_guard_fires.sh` + `test_composition_uid_patch_present.sh`)
  (~15 min): fixture copy of the pre-fix Composition plus a `yq` one-liner.
- Documentation edits (~10 min): four one-line additions.
- Rollout audit (~10 min): no `UID=` check, unit tests locally, README row.
- Review cycle (~5 min): small change surface, no design ambiguity.

Wall-clock wildcard: one `integration-tests.yml` dispatch (60–90 s). Total
implementation including a single dispatch-and-verify cycle stays under one hour.
