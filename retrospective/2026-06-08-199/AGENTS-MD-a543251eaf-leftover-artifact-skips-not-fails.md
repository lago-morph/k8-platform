# agent instruction

**A leaked or value-less test artifact must SKIP, not FAIL, in a live suite.** "When a behavioral check finds a Crossplane-stamped resource that is empty/value-less or a known test leftover (e.g. an ASM secret with no AWSCURRENT version), treat it as SKIP (not-a-healthy-product), not a hard FAIL. A single FAIL turns the whole suite RED; the orchestrator still promotes the SKIP to a FAIL where the kind is expect-full, and the instantiate tier is the rigorous create-and-verify gate."

*Grounded in: auto-014, where a chainsaw-leftover ASM secret (PlatformAbstraction=PlatformSecret, no AWSCURRENT version) made the secretsmanager check exit 1 and turned the whole after-tier RED.*

# justification

A live suite's value is its trustworthiness: it must go RED only for a real regression. A leftover or mid-provisioning artifact — here a chainsaw deletion-scenario secret with zero versions — is indistinguishable from "not really provisioned", and hard-FAILing on it makes the gate cry wolf and trains everyone to ignore red. The fix is to scope health honestly: a value-less container is a SKIP, not a FAIL. This does not weaken the gate, because the inverted-skip orchestrator still promotes a SKIP to a FAIL for any kind declared expect-full, and the instantiate tier creates a real, valued resource and verifies it rigorously. The marginal cost is one extra branch in the check; the cost of getting it wrong is a permanently-distrusted suite.
