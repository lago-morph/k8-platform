# agent instruction

**Chainsaw `status.conditions:` asserts on v2 XRs MUST list all 3 conditions in order.** "Crossplane v2 XRs carry 3 status conditions in this exact order: `Synced`, `Ready`, `Responsive` (the v2 `WatchCircuitClosed` indicator). Kyverno-json (chainsaw's match engine) matches arrays element-wise + length-checked by default; a partial-length assertion returns `lengths of slices don't match` without ever comparing fields. List all 3 conditions in any chainsaw scenario that asserts `status.conditions:`, in the order Crossplane emits them. For new XR kinds added later, verify the condition shape by inspecting one Ready XR in a kind cluster and update accordingly."

*Grounded in: auto-003 chainsaw run 26544796570, where `[Ready]` and `[Synced, Ready]` asserts hit `lengths of slices don't match` against XRs that were actually healthy (Ready=True at t+16s) but had 3 conditions instead of 1-2.*

# justification

Without this rule, every scenario author who writes a "wait for XR Ready" assert gets it subtly wrong against v2 — and the failure looks like a 245s timeout (chainsaw retries the assert until the deadline), not a "your assert shape is wrong" error. The 2026-05-26 session and the auto-003 retry both wasted ~15 minutes diagnosing it before the log showed `lengths of slices don't match`. Cost of adopting: scenario authors include 3 conditions instead of 1-2, and the `tests/unit/test_chainsaw_xr_conditions_complete.sh` enforcer (added in PR #105 commit `8298c1f`) catches drift. Cost of NOT adopting: a 245s timeout per offending scenario per chainsaw dispatch, plus log-reading time. The asymmetry is structurally similar to the em-dash rule but the failure mode is harder to recognize from symptoms alone — adding the rule makes the contract explicit.
