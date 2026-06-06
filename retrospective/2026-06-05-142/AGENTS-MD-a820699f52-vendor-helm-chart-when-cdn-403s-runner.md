# agent instruction

**When a Helm chart repo returns 403/blocks the CI runner, vendor the digest-verified chart instead of fetching at apply time.** "If `helm`/Terraform fails to fetch a chart index from a public repo on the GitHub runner (e.g. `charts.crossplane.io/stable/index.yaml` → 403) while the same URL serves 200 elsewhere, the CDN is restricting the runner egress — do NOT just retry. Download the chart `.tgz`, verify its `sha256` against the repo `index.yaml` `digest`, commit it under `vendor/`, and install from the local path (drop `repository`/`version`). Keep the version variable driving the filename so vendored copies stay in lockstep. Document the revert path."

*Grounded in: 2026-06-05 auto-005 — `charts.crossplane.io` 403d the runner across two management applies; vendoring unblocked it.*

# justification

`charts.crossplane.io` 403'd the GitHub runner on two consecutive management applies while returning 200 from the sandbox — a runner-network restriction, not a transient. Retrying burns ~16-min apply cycles for nothing. Vendoring the digest-verified chart (sha256 matched the upstream index) made the apply hermetic and is arguably more secure than a live CDN fetch. The marginal cost is one ~15 KB tarball in git; the cost of not recognizing the pattern is repeated wasted CI cycles and a session blocked on an external CDN the team does not control.
