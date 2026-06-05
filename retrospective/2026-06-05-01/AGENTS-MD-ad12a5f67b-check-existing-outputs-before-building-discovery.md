# agent instruction

**Check existing module or pipeline outputs before building a discovery mechanism.** Before proposing machinery to obtain a value at runtime — a selector, an EnvironmentConfig, a CI templating step, a data-source lookup — first check whether an earlier stage already exposes that value (a Terraform output, a remote-state attribute, an existing connection secret). If it does, thread the existing value through instead of inventing a new way to rediscover it.

*Grounded in: 2026-06-05 subnet-injection session — three discovery mechanisms were proposed for private subnet IDs that terraform/base already exposes as the private_subnet_ids output and terraform/management already reads via remote state.*

# justification

I proposed three increasingly elaborate ways (a Crossplane tag-selector, an EnvironmentConfig fed by an `aws_subnets` tag lookup, a CI-templating step) to get the platform cluster its private subnet IDs — and produced a multi-paragraph options table and several rounds of file-reading — before the user pointed out the IDs are already a Terraform output that the management module already reads via remote state. The over-engineering cost real session time and the user's patience, and would have added a function install, a feature flag, a render-harness change, and an XRD rewrite for a value that was one line away. The marginal cost of the rule is a single check at design time: "does an upstream stage already hand me this?" That one question would have collapsed the entire spiral.
