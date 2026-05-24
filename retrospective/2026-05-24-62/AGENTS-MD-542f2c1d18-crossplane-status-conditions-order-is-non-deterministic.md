# agent instruction

**§6.X — Do not use positional asserts on Crossplane `status.conditions[]`.** Crossplane controllers (XRD, XR, Composition, Function reconcilers) emit `status.conditions` in non-deterministic order. Chainsaw positional `assert:` blocks on these will fail randomly. Use `kubectl wait --for=condition=<Type>` inside a `script:` block instead — order-agnostic. The same applies to ESO ExternalSecrets and Kyverno ClusterPolicies (verified empirically per this session's chainsaw runs).

*Grounded in: chainsaw run 26346566417 saw XRD conditions in [Offered, Established] order; run 26346745818 saw [Established, Offered] on identical code. Each run had a 50/50 chance of hitting the wrong ordering.*

# justification

This is a Crossplane behaviour, not a bug you can fix in the code under test. The rule's cost is one POSIX-sh script block per condition assertion. The cost of not having it is what we saw: a known-flaky test that retried until it happened to hit the right order, masking other failures.

---
