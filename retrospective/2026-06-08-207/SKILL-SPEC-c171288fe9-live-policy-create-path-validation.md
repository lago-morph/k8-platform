# Spec: `live-policy-create-path-validation`

- **ID**: SKILL-SPEC-c171288fe9
- **Source retrospective**: ../2026-06-08-207.md

## Intent

Safely land an autonomous-run tightening of a LIVE cloud IAM/policy (applied from a branch
before merge) by validating it on a real CREATE path — drive the real controller to create
a resource the narrowed policy must permit, observe it succeed and the platform stay healthy
— rather than trusting a permission simulator, and gate the PR merge behind a
machine-enforced sentinel file until that validation is observed and recorded atomically
with the open-issue flip and the handoff. This earns its place because auto-015 hit three
real traps landing one IAM narrowing (a simulator that denies everything, a validation path
the hub never exercises, an unenforceable "do not merge" note), each of which would silently
recur on the next live-policy change.

## Trigger

- Direct: "tighten the live policy", "narrow the IAM Resource", "validate the policy change
  on a clean build", an open issue of the form "Resource:* not tightened".
- Proactive: any PR that edits a live cloud IAM/policy file (e.g. `terraform/**/irsa.tf`,
  a provider role policy) that an autonomous run intends to apply-and-validate this session.
- Negative: a policy change that only widens permissions (no deny to prove); a static-only
  lint change; a change validated entirely by a clean teardown-rebuild from `main` (then
  the normal §6.35 path applies, no branch-apply window).

## Inputs

- The policy diff (the narrowed statement(s)) and the role/identity it attaches to.
- A live substrate where the controller will CREATE, under the narrowed policy, a resource
  the policy must permit (e.g. a spoke whose Crossplane-created OIDC provider + role exercise
  `CreateOpenIDConnectProvider`/`CreateRole`).
- The open issue the change resolves; the handoff doc; the run-id of the validating apply.

## Outputs

- A terraform/policy change + a paired live deny check (skip-on-unreliable-simulator) + a
  Sid-anchored static source lint.
- A draft PR carrying a failing sentinel-gate unit test.
- On validation: a committed sentinel file (with the run-id + evidence), the open-issue
  RESOLVED flip, and the handoff record — in ONE atomic commit; the PR un-drafted.

## Workflow

1. **Author the narrowing** scoped only to *derivable* resource sets (prefix or tag); leave
   non-derivable ARNs (opaque/random-suffixed) at `*` and say so. Keep the action set
   unchanged (verify a `required-actions` test still passes).
2. **Add the static source lint** — Sid-anchored (parse each statement by its `Sid`) so it
   asserts the narrowed statements stay prefix-scoped AND the deliberately-broad ones stay
   `*`, without false-matching unrelated statements.
3. **Add the live deny check** under the scoped harness identity (grant it the read verb it
   needs, e.g. `iam:SimulatePrincipalPolicy`). Make its in-scope positive control double as
   a simulator-sanity probe: if the positive is itself denied, SKIP (the simulator is
   unusable), never FAIL.
4. **Add the sentinel-gate unit test**: it exits non-zero until a sentinel file
   (`<decisions>/.<gate-id>-passed`) exists. Wire it into the unit suite.
5. **Open the PR as a DRAFT.** Its required unit-tests check is RED via the gate test.
6. **Apply the narrowed policy from the branch** (a validation apply). Confirm the apply
   shows the expected diff (not "No changes" — if it does, you committed to the wrong
   branch; recover before proceeding).
7. **Validate on the CREATE path:** drive the controller to create the resource the policy
   must permit (e.g. sync the manual-sync access claim). Verify via the cloud API that the
   resource was CREATED (crossplane/controller-tagged) and the platform stays healthy
   (composite `Synced=True`, zero managed resources not-Ready).
8. **Clear the gate atomically:** in ONE commit, write the sentinel (with the validating
   run-id + the created ARNs/names as evidence), flip the open issue to RESOLVED, and record
   the observation in the handoff. The gate test goes green.
9. **Un-draft the PR** (mark ready-for-review). If validation could NOT be completed this
   run, leave the draft + gate as-is; the live policy stays narrowed (safe superset on
   revert) and the next session finishes the validation.

## Concrete examples

**Example A — auto-015 OI-2026-06-08-1 (the originating case).** Narrowed
`terraform/management/irsa.tf` IAM to `role/k8-platform-*` + `oidc-provider/*`; added
`test_iam_resource_scoping.sh` (Sid-anchored lint, 10/0), `iam-resource-scope-denied.sh`
(simulate-based, skip-on-unreliable), `test_iam_tightening_gate.sh` (sentinel). Opened #203
as a draft. Applied the policy (run 27157161037, "2 changed"). Synced `spoke-access`; the
hub created `oidc-provider/.../id/B58BD65...` + role `k8-platform-k8-platform-services-external-dns`
+ its inline policy under the narrowed policy (all crossplane-tagged); `XPlatformCluster
platform` stayed `Synced=True`. Committed `.auto-015-iam-gate-passed` + flipped the OI +
recorded it; un-drafted #203.

**Example B — a deferred case (RDS).** The same brief found RDS *is* derivable
(`xdatabase.yaml` pins the external-name to the XR name ⇒ `db:<xr-name>`), but no
Keycloak-DB provision ran this session to exercise the narrowed RDS create — so the RDS
tightening was NOT authored; it was filed as a follow-up on the open issue, gated on the
provision that would validate it. The skill declines to ship a narrowing whose CREATE path
nothing provisions this run.

## Anti-patterns

- Trusting `simulate-principal-policy` as the firing proof (auto-015: it returned
  `implicitDeny` for `eks:DescribeCluster` on a `*` allow — unusable on a fresh role).
- Validating on a path the hub never exercises (the hub roles are Terraform-created; only
  the spoke's controller-created roles test the narrowing).
- A prose "do not merge" note instead of a draft + failing sentinel check.
- Narrowing a non-derivable ARN set (opaque/random-suffixed) — it breaks the next reconcile
  silently; leave it `*` and document why.
- Committing the narrowing to the wrong branch (verify `git branch --show-current` first) —
  the symptom is a validation apply that reports "No changes".

## Acceptance criteria

1. The narrowed policy applies with the expected diff and the platform reconciles
   `Synced=True` with zero managed resources not-Ready afterward.
2. The cloud API confirms the controller CREATED the in-scope resource(s) under the narrowed
   policy (controller-tagged), proving the allow path.
3. The static lint catches BOTH re-widening and premature over-narrowing.
4. The PR cannot be merged until the sentinel is committed; the sentinel, the issue flip,
   and the handoff record are one atomic commit.
5. A narrowing whose CREATE path is not provisioned this run is deferred, not shipped.

## Files this skill creates / modifies

- `terraform/**/<role>.tf` — the narrowed policy statement(s).
- `tests/unit/test_<thing>_resource_scoping.sh` — the Sid-anchored source lint.
- `tests/live/checks/negative/<thing>-resource-scope-denied.sh` — the live deny check.
- `tests/unit/test_<gate-id>_gate.sh` + `<decisions>/.<gate-id>-passed` — the sentinel gate.
- `docs/open-issues.md` + the handoff — flipped/recorded atomically with the sentinel.
