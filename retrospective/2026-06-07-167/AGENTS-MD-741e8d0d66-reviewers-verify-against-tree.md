# agent instruction

**Adversarial and synthesis subagents must verify load-bearing claims against the tree.** "Brief adversarial and synthesis subagents to verify every load-bearing factual claim against the actual repo files, not just reason about the document; plan-level facts (a ProviderConfig source, a CRD api version, an endpoint flag) are routinely wrong and only tree-grounding catches them."

*Grounded in: 2026-06-07 — tree-grounded reviewers caught `source: IRSA` (not `InjectedIdentity`), v1-vs-v2 claim-verify, Pipeline-mode MR-kind paths, and the spoke being public; document-only reasoning would have shipped all four wrong.*

# justification

Across three review rounds the highest-value findings were not matters of opinion — they were facts checked against the repository: the AWS ProviderConfig is `source: IRSA`, not `InjectedIdentity` (that belongs to a different provider); `crossplane-claim-verify` is v1-claim-shaped (`spec.resourceRefs`) while the repo is v2 namespaced-XR; composition managed-resource kinds live under `spec.pipeline[].input.resources[].base`, not `spec.resources[]`; the spoke EKS endpoint is public (`endpointPublicAccess: true`), so it was wrongly diagnosed as unreachable. Each was a plan error that would have shipped. Reviewers who only reasoned about the prose missed them; reviewers explicitly instructed to grep the tree caught them and cited file:line. The lesson is cheap to apply and high-leverage: every adversarial or synthesis brief must require verifying load-bearing claims against the actual files, and the briefs should name the files to check.
