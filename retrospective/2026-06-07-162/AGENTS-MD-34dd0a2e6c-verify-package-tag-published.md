# agent instruction

**Verify a Crossplane package tag is published and Crossplane-version compatible before pinning it.** "Before pinning any Crossplane provider/function package tag in terraform or a Provider/Function manifest, confirm the exact tag exists in `xpkg.upbound.io` (the Upbound marketplace listing, or a registry manifest HEAD) AND that the release supports the cluster's Crossplane major version. `crossplane render`, kubeconform, and `terraform plan` do NOT validate the package reference, so a wrong or non-existent tag passes every local/CI gate and fails only at live install with `cannot unpack package: ... MANIFEST_UNKNOWN ... 404`."

*Grounded in: auto-011 — provider-kubernetes:v0.16.0 was never published to xpkg and predated Crossplane v2; only the live management apply caught it.*

# justification

A subagent guessed `xpkg.upbound.io/crossplane-contrib/provider-kubernetes:v0.16.0`. It survived render, kubeconform, and a clean `terraform plan`, and only failed after a full management `apply-and-verify` reached its last step with `MANIFEST_UNKNOWN` — burning a ~20-minute live apply cycle. The registry actually publishes v0.18.0 and the v1.x line, with v1.0.0+ being the first Crossplane-v2 release. A single marketplace check (or a registry HEAD) takes seconds and is the only thing that catches a bad package reference, because none of the local gates inspect it. The cost asymmetry — seconds of verification vs a failed live apply on a production cluster — makes this mandatory before pinning.
