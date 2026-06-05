# agent instruction

**function-patch-and-transform: combine cross-source values via top-level environment.patches.** To build a value that combines an XR field with an EnvironmentConfig field (e.g. a wildcard domain from spec.dns.subdomain + env.domain), stage the XR field into the environment with a TOP-LEVEL `environment.patches` entry (which runs before resource patches) and then CombineFromEnvironment on the resource. A per-resource ToEnvironmentFieldPath write is NOT visible to a CombineFromEnvironment in the same render/reconcile pass; the top-level environment patch is.

*Grounded in: 2026-06-05 phase-3 — the cert domainName rendered empty until the subdomain→env write moved from a per-resource patch to a top-level environment patch.*

# justification

Two render iterations were burned discovering that function-patch-and-transform's combine reads the environment as it stood at the start of the pass, so a same-resource (or earlier-resource) ToEnvironmentFieldPath write produces nothing for a CombineFromEnvironment later in the same pass. The fix — a top-level `environment.patches` block, which P&T applies before any resource patches — is non-obvious and thinly documented. CombineFromComposite and CombineFromEnvironment also each require all variables from a single source, so combining an XR field with an env field forces this staging. Recording the rule saves the next author the same two-iteration rediscovery on any cross-source combination (cert domains, ARNs, names) — a recurring need in cluster Compositions.
