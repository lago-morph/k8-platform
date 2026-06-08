# agent instruction

**Verify behavior coupled to the build, under the real identity.** A test must prove the thing *works*, not that a manifest *says* it does. Static `yq`/`grep` checks are the push/PR floor only — never the oracle. The center of verification is driving the real controller under its real IRSA identity and checking the real cloud resource, on by default and coupled to the build (verified when you build it, not on a schedule). Cluster/live work is `workflow_dispatch`-only; push/PR stays static. Never weaken a behavioral check down to a green lint.

*Grounded in: driving the real Composition on a second live cluster surfaced a upjet provider bug and a missing IAM permission that render/yq lints could never have seen.*

# justification

Authoring the relay wiring passed every static check — kubeconform, the render golden, the unit lints. Only running the real Composition under the real crossplane IRSA identity on a live second cluster revealed that `provider-aws-ec2 v2.5.0` cannot observe `SecurityGroupIngressRule` (a terraform-provider-aws v6 resource-identity regression) and that the crossplane role lacked `ec2:AuthorizeSecurityGroupIngress`. Both would have shipped silently and bitten on the next real deploy. The rule (ADR-0006) costs dispatch time for a live run; not having it costs serial production discoveries of the unknown-missing-permission / broken-provider class — the exact failure mode that has cost this repo weeks.
