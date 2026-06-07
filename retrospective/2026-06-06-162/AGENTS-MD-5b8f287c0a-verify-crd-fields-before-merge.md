# agent instruction

**Verify provider CRD field names against the live cluster before merging composition code.** "`crossplane render` and kubeconform validate against locally-authored JSON schemas, not the live provider CRDs, so a wrong `forProvider`/`status` field name or enum value passes every local check and fails only at apply time. Before merging a new Composition that uses provider fields you are unsure of, dump the real CRD schema from the running cluster (e.g. via kube-diagnose `kubectl get crd <x> -o jsonpath`) and confirm the field names and enum values."

*Grounded in: auto-011 — the XSpokeAccess subagent flagged 3 uncertain live fields; a single CRD dump confirmed all 3 before merge.*

# justification

The XSpokeAccess composition passed `crossplane render` (golden match) and kubeconform, yet the author explicitly could not know whether `AccessEntry.status.atProvider.accessEntryArn`, `OpenIDConnectProvider.status.atProvider.arn`, and `AccessEntry spec.forProvider.type: STANDARD` matched the installed provider v2.5.0 — because the local schemas were authored by the same agent. One kube-diagnose CRD dump confirmed all three (and the AccessPolicyAssociation required fields), converting "merge and hope" into "merge with evidence." The check is a single read-only CI run; the alternative is discovering a wrong field name 20 minutes into a live management apply and re-cycling. For composition code targeting provider CRDs the agent didn't write, the live schema is the only source of truth.
