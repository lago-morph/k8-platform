# Decision brief auto-006 — permanent fix for the ASM `ResourceExistsException` rotation flake

**Run.** long-run-BYIB6 (auto-005). **Status.** Round 1 (awaiting adversarial wave 1).
**Tracks.** OI-2026-05-28-1 Issue A (`docs/open-issues.md`).

---

## Question

How do we permanently fix the recurring chainsaw flake where an
`XPlatformSecret`'s ASM Secret managed resource (MR) never reaches `Ready`
within 240s, with the provider error:

```
CannotCreateExternalResource ... ResourceExistsException: The operation
failed because the secret k8-platform/<xr-uid> already exists.
```

Observed on `claim-rotation` (run 26621695077) and earlier as a bare
`Ready=False reason=Creating` on `composition-drift` (run 26552671925).
Same Composition, fresh kind cluster per run, intermittent.

**Root-cause hypothesis (per OI register, labelled hypothesis per §6.17):**
a `CreateSecret`/`Observe` double-create race. The Upbound AWS provider
(upjet) issues `CreateSecret`; a second reconcile re-issues `CreateSecret`
before the first secret's ID is persisted to `crossplane.io/external-name`
(AWS Secrets Manager read-after-write lag) → `ResourceExistsException`, and
the MR can get stuck re-attempting Create rather than adopting the existing
secret.

## Alternatives (≥3 named options)

**Option A — set `crossplane.io/external-name` on the ASM Secret MR
(deterministic, up-front).** Patch the annotation to the same value the
secret is named (`k8-platform/<metadata.uid>`). With external-name set, the
provider always *Observes* (DescribeSecret) by that ID first and *adopts* an
existing secret instead of blind-Creating — closing the double-create window.
This is the OI register's candidate (c) and the only option that targets the
hypothesised root cause. Cost: a Composition change → SPEC-S9 render-golden
regen → **live chainsaw re-confirmation required before merge** (the fix
cannot be verified statically). Risk/uncertainty: the exact external-name
*format* upjet expects for `secretsmanager.aws.m.upbound.io` Secret (friendly
name `k8-platform/<uid>` vs full ARN) is unconfirmed — if upjet expects the
ARN, setting the friendly name could itself cause an Observe miss. **This is
the load-bearing uncertainty the adversarial wave must attack.**

**Option B — serialize chainsaw scenarios** (`tests/chainsaw/run.sh` runs
scenarios sequentially, not in parallel). Lowers concurrent provider load,
reducing read-after-write contention. Masks the race in CI; does **nothing**
for production (where two reconciles of the same XR can still race) and slows
the suite. Test-only band-aid.

**Option C — raise `claim-rotation`'s assert timeout above 240s.** Pure
mask: only helps if the MR eventually self-heals (the OI evidence suggests it
can get *stuck* re-Creating, in which case no timeout is long enough). Hides
the signal; rejected as a primary fix.

**Option D — provider-level retry/backoff or `managementPolicies` tweak**
(e.g. add `Import`, or rely on the provider's own conflict handling). Vague;
no concrete upstream knob identified; deferred unless A is infeasible.

## Decision (Round-1 best call)

**Option A**, with two hard gates before it merges:
1. **Confirm the external-name format** upjet expects for this MR kind
   (read the provider CRD / upstream docs; do NOT guess).
2. **Live chainsaw re-confirmation** on a fresh account (attended) — author
   this run produces the *proposal* + a static regression test only; it does
   **not** merge the Composition change blind (sandbox has no live creds;
   §6.8 requires live admission for v2 CRD-shape changes).

Until both gates pass, the code change stays unmerged; this run delivers the
brief + the OI-register update + a static test that pins the contract.

## Reasoning

- A is the only option addressing the root cause; B/C/D mask.
- The OI register already ruled out stale credentials and a Task-2
  regression, and sharpened the hypothesis to the create/observe race — A
  directly targets that.
- The cost of A (golden regen + live chainsaw) is real but one-time; B/C are
  recurring taxes (slower suite / hidden failures).

## Downstream impact

- `crossplane/compositions/platform-secret.yaml` — +1 patch (annotation).
- `crossplane/xrds/platform-secret/render-fixtures/expected.yaml` — regen
  (the asm-secret MR's `metadata.annotations` changes from `{}`).
- `docs/open-issues.md` — OI-2026-05-28-1 Issue A: hypothesis → proposed fix,
  pending live verification (NOT closed — unverified).
- New static test pinning the external-name contract (see the test plan under
  adversarial review).

## Round-1 if-user-overrides rewind point

Revert the commit that adds this brief. No production code changes in Round 1
— the brief is analysis only.

---

## Round-1 adversarial review

_Dispatched: 3 real subagents (angles: upstream-provider skeptic, race-theory
challenger, test-altitude purist). Findings folded into Round 2 below._

<!-- Round-2 section appended after wave 1 returns. -->
