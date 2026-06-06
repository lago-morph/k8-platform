# agent instruction

**Bake the confirming diagnostics into a fix whose acceptance is a live run.** When a fix can only be validated by observing a live run (e.g. a cluster apply, a CI workflow), build the diagnostics that would *confirm the root cause* into the fix itself, on the failure path. That way a single live run both tests the fix and gathers the evidence that distinguishes the real cause from competing hypotheses — instead of leaving the cause a hypothesis that needs a second run to prove.

*Grounded in: auto-009 — a broadened failure-path dump baked into the provider-SA fix captured the `cannot build DAG ... already exists` Lock condition, confirming the duplicate-Provider root cause on the very run that tested the fix.*

# justification

Live-run validation is expensive — a cluster apply or a CI cycle can take many minutes and can only be triggered serially. In auto-009 the provider-SA fix carried a broadened failure-path dump (`describe providerrevision`, `get lock -o yaml`, crossplane controller logs). Validation-1 failed, but the dump captured the crossplane Lock condition `cannot build DAG: node ...provider-family-aws already exists` — which *confirmed* the duplicate-Provider root cause and directly answered adversarial reviewer #1's objection ("is this really the duplicate, or a package-manager-wide stall?"). Had the diagnostics not been baked in, that failed run would have produced no evidence, the root cause would have stayed a labelled hypothesis, and a whole additional live cycle would have been needed just to instrument-and-rerun. The marginal cost is a few extra describe/log commands on a code path that only executes when the fix fails anyway; the payoff is that every live run does double duty as both test and proof.
