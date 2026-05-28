# Open Issues — durable register of undiagnosed problems

Anything observed that we did not fully diagnose goes here. Per AGENTS.md
§6.14 ("Never ignore an undiagnosed failure"), an open issue is a
hard requirement — we record what happened, what we ruled out, and the
next concrete diagnostic step. The list shrinks as items get closed
(with evidence) and grows as new ones surface.

Each entry uses the format below. Identifier `OI-YYYY-MM-DD-N` where N
is the sequence number for that date.

---

## OI-2026-05-28-1 — `composition-drift` first-scenario timeout on chainsaw

**Status:** **partially diagnosed** — Issue B (cleanup path bug) root-caused
with verbatim log evidence; Issue A (first-scenario XR-Ready timeout) still
hypothesis-level.
**Surfaced:** 2026-05-28, PR #125 chainsaw dispatch (run id `26552671925`,
HEAD SHA `b31cc87`).
**Re-dispatch:** 2026-05-28, run `26553581065` against the same SHA produced
a DIFFERENT failure pattern, which is what surfaced Issue B.

### Issue B — `composition-drift` cleanup silently fails to restore the mutated Composition

**Status:** **diagnosed.** Fix is small and obvious.
**Root cause:** The composition-drift scenario's
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

---

<!-- New entries go above this line, newest first. -->
