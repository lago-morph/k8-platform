# agent instruction

**Verify package tags against upstream source before pinning.** "When pinning a software version (Helm chart version, Crossplane package version, OCI image tag, terraform module version), fetch the exact tag URL on the upstream source repository (GitHub releases page, repo's `git ls-remote`, or equivalent) and confirm it returns 200/exists before writing the pin. Do not trust marketplace listings or aggregator UIs alone — they sometimes list versions not present upstream."

*Grounded in: session 2026-05-26 Phase 3 — Upbound Marketplace listed `provider-aws-secretsmanager v2.5.4`; the upstream `crossplane-contrib/provider-upjet-aws` repo has no such tag (latest is v2.5.0). PR #98 was merged with the nonexistent tag, requiring a follow-up #100 fix.*

# justification

The original v1→v2 bump (PR #98) used `v2.5.4` because the Upbound Marketplace UI listed it as the latest. The actual upstream tag is `v2.5.0`. Without the catch from the SEG-4B adversarial reviewer (who ran `WebFetch` against the upstream URL pattern `https://github.com/crossplane-contrib/provider-upjet-aws/tree/v2.5.4` and got a 404), the next `terraform apply` and the next `chainsaw.yml` dispatch would both have 404'd at the package-fetch step.

Diagnosis time after a 404 in this class of failure is typically hours: the agent has to suspect the version pin is wrong (the user reports a vague "the apply failed"), then check the tags page, then find the nearest version, then amend the pin, then re-trigger the apply. Pre-verification flips this — one extra `curl -I` (or one `WebFetch`) at pin time saves the entire post-failure debug loop.

The marginal cost of the rule is one network call per version pin. The asymmetric cost saved is, in this session's case, an entire PR (#100) plus the chainsaw-verify back-and-forth on the rebased branch. Future incidents likely cost more — staging a new cluster against a nonexistent provider tag would cause production-grade apply failures.

The rule is non-negotiable for marketplaces specifically because marketplaces commonly index synthetic versions (planned releases, beta tags, or simply data-entry errors). The upstream source URL is the only endpoint where a 404 means definitively "does not exist."
