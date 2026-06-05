# Open Issues — durable register of undiagnosed problems

Anything observed that we did not fully diagnose goes here. Per AGENTS.md
§6.18 ("Never ignore an undiagnosed failure"), an open issue is a
hard requirement — we record what happened, what we ruled out, and the
next concrete diagnostic step. The list shrinks as items get closed
(with evidence) and grows as new ones surface.

Each entry uses the format below. Identifier `OI-YYYY-MM-DD-N` where N
is the sequence number for that date.

---

## OI-2026-05-28-1 — `composition-drift` first-scenario timeout on chainsaw

**Status:** **partially resolved** — Issue B (cleanup path bug) **RESOLVED**
(fix landed in PR #129; verified in code 2026-05-29); Issue A (first-scenario
XR-Ready timeout) still **open**, hypothesis-level.
**Surfaced:** 2026-05-28, PR #125 chainsaw dispatch (run id `26552671925`,
HEAD SHA `b31cc87`).
**Re-dispatch:** 2026-05-28, run `26553581065` against the same SHA produced
a DIFFERENT failure pattern, which is what surfaced Issue B.

### Issue B — `composition-drift` cleanup silently fails to restore the mutated Composition

**Status:** **RESOLVED** (verified 2026-05-29, auto-004). The fix already
landed via PR #129 (commits `0e31154` "restore Composition from /tmp
snapshot, not cwd-relative on-disk path" + `e834a8a` "strip read-only
fields from pristine snapshot"). `tests/chainsaw/_meta/composition-drift/chainsaw-test.yaml`
now snapshots the pristine Composition to `/tmp/composition-pristine.yaml`
in the mutate step and restores from that path (CWD-independent) guarded by
`if [ -f ... ]` with **no `|| true`** — so a future restore failure exits
non-zero immediately instead of cascading. The register entry below was
stale; closing it. Real-AWS chainsaw re-confirmation is the last step.
**Root cause (historical):** The composition-drift scenario's
"restore the Composition (cleanup)" script runs:
```sh
kubectl apply -f crossplane/compositions/platform-secret.yaml || true
```
Chainsaw runs scripts with its own CWD (under `tests/chainsaw/`), not the
repo root, so the relative path doesn't resolve. The `|| true` swallows the
error. Verbatim from run `26553581065` log:
```
error: the path "crossplane/compositions/platform-secret.yaml" does not exist
```
**Consequence:** When `composition-drift` reaches the mutation step (which
it did in run `26553581065` but not in run `26552671925`, see Issue A), the
on-cluster Composition stays at `recoveryWindowInDays: 7`. All subsequent
scenarios (`claim-creates-secret`, `claim-rotation`, `claim-deletion-cleanup`)
reconcile against the mutated Composition. Their goldens assert
`recoveryWindowInDays: 0` and fail with diff at the chainsaw assert timeout
(~249-253s). This is the cascading triple-failure observed in run `26553581065`.
**Fix:** (1) compute the composition path absolutely (e.g. `$(git rev-parse
--show-toplevel)` or chainsaw's `$CHAINSAW_ROOT` if it sets one); (2) drop
the `|| true` so the next time the apply fails, the cleanup step exits
non-zero and the failure is visible immediately rather than cascading.
**Next action:** open a stacked PR (Task 6) with the fix. Hold pending
user confirmation per §6.5.

### Issue A — `composition-drift`'s XR takes >245s to become Ready (first run only)

**Status:** still hypothesis-level. The Issue B diagnosis does NOT explain
Issue A — in run `26552671925` the XR was Unready at `wait for XR Ready`'s
245s timeout BEFORE composition-drift could reach the mutation step. The
asm-secret MR had `status.Ready=False, reason=Creating`. In run
`26553581065` the same XR became Ready in time. Both runs were on the same
SHA, same composition, fresh kind cluster per run.
**Hypotheses (UNCONFIRMED — no positive evidence):**
- AWS-provider cold start that varies between dispatches.
- IAM permission propagation lag on the freshly-issued GHA access key
  (a few-minutes window where the key works for some calls and not
  others).
- Transient AWS API throttling or upstream provider hiccup.
**Ruled out:**
- Stale credentials (`§8.2`): later scenarios in the FIRST run authenticated
  and provisioned ASM secrets successfully via the AWS CLI; later scenarios
  in the SECOND run also authenticated (their failure was the
  recoveryWindowInDays diff, not an AWS API error).
- Regression from Task 2: `git diff main chore/audit-wiring-fixes-2026-05-02
  -- crossplane/ tests/chainsaw/` is empty.
**Next diagnostic step:** the catch block now uses `-A` (post the
chore/audit-wiring-fixes-2026-05-05 fix) so the asm-secret MR's
`status.conditions` and `status.atProvider` will be captured on the next
occurrence. Re-dispatch only after Issue B is fixed (so subsequent
scenarios don't cascade-fail and obscure Issue A).
**Owner / next action:** Issue A defers; Issue B is the immediate fix.

**2026-05-29 update (auto-004, NEW POSITIVE EVIDENCE — run `26621695077`):**
Recurred on a fresh account, this time on the **`claim-rotation`** scenario
(not composition-drift). 5/6 real-AWS scenarios passed
(`claim-creates-secret` in 10.7s, `claim-deletion-cleanup`, `composition-drift`,
`xrd-establishes`, `_smoke`); only `claim-rotation` failed at the
`wait for claim Ready` 240s timeout. The catch block captured the actual
provider error (the earlier occurrences only showed `Ready=False,
reason=Creating`):
```
CannotCreateExternalResource ... ResourceExistsException: The operation
failed because the secret k8-platform/<xr-uid> already exists.
```
This **sharpens the hypothesis** from "XR is just slow" to a **CreateSecret /
Observe double-create race**: the AWS provider issues `CreateSecret`, then a
second reconcile re-issues `CreateSecret` before the first is observable
(AWS Secrets Manager read-after-write lag) → `ResourceExistsException`, and
the MR can get stuck re-attempting create rather than adopting the existing
secret, so the XR never reaches Ready within 240s. Consistent with
"flaky / load-dependent" (the same Composition's `claim-creates-secret`
passed in 10.7s in the same run). Still **hypothesis**, not confirmed —
candidate fixes to evaluate if it recurs deterministically:
(a) run chainsaw scenarios serially (reduce parallel provider load),
(b) raise `claim-rotation`'s assert timeout above 240s,
(c) investigate the provider's external-name persistence after first
    CreateSecret (the real fix if the MR never self-heals).
Also noted: `tests/chainsaw/run.sh`'s cleanup trap deletes by
`ASM_PREFIX="k8-platform-chainsaw"`, but the Composition names secrets
`k8-platform/<uid>` — so scenario secrets are NOT swept by the prefix
cleanup (they linger until manually removed). Separate minor issue; logged
here for the next session. **Next action:** re-kicked chainsaw once to test
the flake hypothesis (auto-004).

---

## OI-2026-06-05-1 — `yq/awk | grep -q` under `set -o pipefail` flakes unit tests

**Status:** **RESOLVED** (diagnosed + fixed, auto-005 long-run).
**Surfaced:** 2026-06-05, full local `tests/unit/run.sh` run during the
auto-005 audit — `test_platform_cluster_composition.sh`'s
`composition_policy_AmazonEKSWorkerNodePolicy` assertion failed
intermittently (`missing policyArn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy`).

**Root cause (CONFIRMED by repro + fix, not hypothesis):** the assertion ran
`yq -r "...resources[]...policyArn..." "$COMP" | grep -qF "$arn"` under
`set -uo pipefail`. `grep -q` exits on its first match and closes the pipe;
the still-writing `yq` then takes `SIGPIPE` (exit 141), and `pipefail`
propagates that 141 as the pipeline's status, so the `if` intermittently
takes the `else` branch and emits a false FAIL. Measured **~10% (2-3/20-30)**
before the fix.

**Fix:** capture the producer's output to a variable, then `grep -q … <<<"$var"`
(here-string — no upstream process to receive SIGPIPE). Applied to every
instance of the class found in `tests/unit/`:
- `test_platform_cluster_composition.sh` (the observed one),
- `test_argocd_bootstrap.sh` (2 sites, `awk … | grep -q`),
- `test_diag_component.sh` (2 sites, `awk … | grep -q`).
`yq --version | grep -q mikefarah` sites were left as-is (single-line output,
producer already exited — no SIGPIPE window).

**Verification:** the previously-flaky test ran **0/30** failures after the
fix (was ~3/30). All three touched tests pass standalone.

**Prevention note (candidate AGENTS rule / lint):** "Never `producer | grep
-q` under `pipefail` when the producer emits more than one line — capture and
`grep -q <<<"$var"`." Surfaced for the retro.

---

## OI-2026-05-28-1 Issue B-adjacent — ASM cleanup-trap gap: **RESOLVED**

**Status:** **RESOLVED** (auto-005 long-run). The "Also noted" item in
OI-2026-05-28-1 below — `tests/chainsaw/run.sh` swept ASM secrets by
`${ASM_RUN_PREFIX}/` (`k8-platform-chainsaw-<id>/`) while the Composition
names them `k8-platform/<uid>`, so they never matched and leaked — is fixed.
The cleanup now enumerates the real names from the Secret MRs in the live
kind cluster (`tests/chainsaw/_lib/asm-cleanup.sh`) and deletes exactly
those, before `kind delete`. Behavioral unit test:
`tests/unit/test_chainsaw_asm_cleanup.sh`. (Issue A — the
`ResourceExistsException` rotation race itself — remains open; see decision
brief `decisions/auto-006-asm-external-name-fix.md`.)

---

<!-- New entries go above this line, newest first. -->
