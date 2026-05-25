# agent instruction

**`terraform_data` resources with `local-exec` must hash every dependency.** When a `terraform_data` resource carries a `local-exec` provisioner that templates an inline YAML or command body, `triggers_replace` MUST cover every distinct body the command depends on — manifest content via `sha256(local.<body>)`, file-backed bodies via `filesha1("<path>")`, command-body changes via an explicit version sentinel. Listing only the templated input values (an IAM role ARN, a chart version) is NOT enough: a body-only edit silently no-ops at apply time, reporting `Apply complete! Resources: 0 added, 0 changed, 0 destroyed`. The pattern to copy in this repo is `terraform_data.argocd_bootstrap`'s `filesha1(...)` in helm.tf.

*Grounded in: PR #66's manifest pin was a no-op until PR #67 added `sha256(local.crossplane_aws_provider_manifest)`; PR #68 then needed a `"provisioner-command-v2"` sentinel for a command-body-only change.*

# justification

The IRSA-fix chain consumed five PRs (#66, #67, #68 — plus #69, #70 on the related infrastructure) over an extended debug loop. Two of those PRs (#67, #68) existed *purely* to undo the consequence of missing dependency hashes in `triggers_replace`. The marginal cost of the rule is two lines (`sha256(local.x)` plus the `locals { x = <<-EOT … EOT }` extraction) per `terraform_data` resource — once per resource, forever. The cost of not having the rule is one silent no-op apply per edit, which costs a full diagnose-and-rediscover cycle (~10 minutes on a small cluster, much more on a real EKS apply). The pattern is mirrorable from `terraform_data.argocd_bootstrap` (helm.tf:360–363), so adoption is mechanical: every existing `terraform_data` resource in `terraform/management/helm.tf` should be audited against this rule.
