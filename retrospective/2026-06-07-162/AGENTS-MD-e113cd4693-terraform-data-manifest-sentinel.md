# agent instruction

**A `terraform_data` that applies an inline manifest must carry a manifest-body sentinel in `triggers_replace`.** "When a `terraform_data` resource `kubectl apply`s an embedded manifest via a local-exec provisioner, a body-only edit (e.g. adding `runtimeConfigRef`, changing an annotation) does NOT change the version-variable triggers, so `terraform apply` silently no-ops the edit and reports 'Apply complete, 0 changed' while the live object stays unchanged. Whenever you edit such a manifest body, add or bump an explicit sentinel string — or a `sha256()` of the manifest local — in that resource's `triggers_replace`."

*Grounded in: auto-011 — adding runtimeConfigRef to the six child-provider manifests required a `runtimeconfigref-irsa-2026-06-06` sentinel on each triggers_replace; helm.tf already documents this exact trap three times.*

# justification

This codebase has been bitten by this trap repeatedly — `helm.tf` carries three separate comments about manifest-body edits no-op'ing the apply (the family-provider `sha256(manifest)` trigger exists precisely for this). When adding `runtimeConfigRef` to the child providers, omitting the sentinel would have produced a deceptive green apply ("0 changed") while the live providers stayed broken and every managed resource kept failing — a silent failure that looks like success and is maddening to debug. A sentinel is one array element; the cost of forgetting it is a green-but-wrong apply and continued live breakage.
