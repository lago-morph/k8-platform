# agent instruction

**Gate expensive/real-cloud chainsaw scenarios out of the per-PR kind matrix.** "A chainsaw scenario that provisions live cloud resources (an RDS instance, a real EKS cluster, anything taking minutes or needing a provider the kind harness does not install) MUST mark itself with a `REAL-AWS / NIGHTLY` header AND be excluded from the default per-PR run by `tests/chainsaw/run.sh` unless `CHAINSAW_INCLUDE_REALAWS=1`. A documentation-only do-not-run-me-here header is not enough — run.sh must actually skip it, or it reds every push in ~35s when the resource cannot be created. Author-time coverage stays via render-fixtures + unit tests; the live flow runs in the dedicated live step or a nightly real-AWS workflow."

*Grounded in: auto-010 chainsaw run 27072199866.*

# justification

A chainsaw scenario that provisions a live RDS instance (xdatabase 01/02) ran in
the per-PR kind-only matrix, which has no provider-aws-rds, and failed in ~35s —
reding the whole chainsaw run (27072199866) even though the phase-2 scenarios all
passed. The scenarios already carried a "REAL-AWS / NIGHTLY — DO NOT run in the
per-PR kind-only matrix" header, but run.sh never read it, so the documentation
was inert. The marginal cost of real gating is one grep in run.sh + one opt-in
env var; the cost of not having it is a red heavy-CI check on every push and a
blocked merge, plus the risk of unmonitored real-cloud provisioning (and orphans)
in a context that cannot tear them down.
