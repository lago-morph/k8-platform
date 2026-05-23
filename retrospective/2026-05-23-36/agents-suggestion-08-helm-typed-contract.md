# AGENTS.md suggestion: Treat helm chart values as a TYPED contract

## Proposed addition

> **§10.2 Treat helm chart `set { name = "..." }` blocks as a
> typed contract.** For every `helm_release` resource in the repo,
> there must be a corresponding `tests/unit/test_helm_render.sh`
> assertion that proves the rendered output meets the contract the
> Terraform code intends. The chart's value schema is not enforced
> by Terraform; the only check is what the unit test asserts.
>
> When adding or modifying a `set` block, add or update the
> matching assertion in the same commit.
>
> *Grounded in: the 2026-05-23 phase-1 strikes 3 (argocd IRSA on
> wrong SA), 6 (bitnami chart values structure), and 7 (argocd
> ingress.hosts vs ingress.hostname) — all three were silent
> chart-key mismatches that produced rendered manifests not
> matching intent. Three distinct strikes for the same bug class.*

## Why this earns its place in your agents file

Three of the seven phase-1 strikes (3, 6, 7) were the same class:
a `set` block whose key path didn't match the chart's value
schema, producing a rendered manifest that compiled fine but
ignored the value. None of these would have been caught by
`terraform plan` or `terraform apply` — they only surface at
runtime when the rendered K8s object behaves wrong. The unit-test
layer was specifically added in PR #34 to address this, but the
discipline of "every `set` block has an assertion" isn't yet
codified anywhere. Codifying it makes the discipline reviewable
in the PR diff.
