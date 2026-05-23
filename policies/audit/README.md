# Kyverno audit-mode policies

These ClusterPolicies run in `validationFailureAction: Audit` mode — they
do not block apply or admission, they only record violations as PolicyReport
CRs and events. Use the `scripts/kyverno-violations.sh` helper to inspect
current state.

The policies encode invariants the management cluster's bootstrap stack is
meant to satisfy. They are deliberately a different testing modality from
`tests/unit/`:

| Layer | When it runs | What it sees | Catches |
|---|---|---|---|
| `tests/unit/test_helm_render.sh` | pre-apply, local | rendered helm output | wrong chart keys, missing values |
| Kyverno audit policies | continuously, in-cluster | live cluster state | drift from any source (helm bump, hand-edit, Argo sync, new namespace) |
| `tests/integration/` | on demand, in-cluster | end-to-end behaviour | broken IAM, missing CRDs, real cloud round-trips |

Each policy file is named `NN-purpose.yaml` so they apply in a stable order
and read top-to-bottom in this directory.

## Lifecycle

- Policies are applied at apply time by `terraform_data.kyverno_audit_policies`
  in `terraform/management/helm.tf`. The trigger is a hash over this
  directory — touching any file here causes a re-apply on next `terraform apply`.
- Once Argo is wired to manage this directory (planned for phase 4), the
  terraform_data block becomes the bootstrap-only path and ArgoCD owns
  ongoing reconciliation.
- Promoting a policy to `Enforce` is a deliberate, per-policy change — most
  should stay in Audit so the platform is observable but not brittle.

## What's catched today

- `01-argocd-server-irsa.yaml` — argocd-server SA in `argocd` namespace must
  have `eks.amazonaws.com/role-arn` annotation. Catches the v1 strike-3 bug
  where the IRSA annotation landed on the wrong SA.
- `02-ingress-must-have-class.yaml` — every Ingress must set
  `spec.ingressClassName`. Ingress without a class is silently unmanaged.
- `03-ingress-managed-by-external-dns.yaml` — any Ingress with a host
  matching `*.management.*` must carry the `external-dns.alpha.kubernetes.io/hostname`
  annotation. Otherwise ExternalDNS won't create the Route53 record.
- `04-irsa-rolearn-format.yaml` — when an SA has the IRSA annotation, the
  value must match `arn:aws:iam::\d{12}:role/.+`. Catches typos and templating
  errors that produce empty or malformed ARNs.
- `05-no-default-sa-with-workload.yaml` — Deployments/StatefulSets must not
  rely on the `default` ServiceAccount. Forces explicit SA hygiene.
- `06-image-tag-not-latest.yaml` — disallow `:latest` and untagged images.
  Drift detection only works if image versions are pinned.
- `07-helm-release-labels-required.yaml` — every Deployment in our managed
  namespaces must carry the `app.kubernetes.io/managed-by` label so we can
  tell ArgoCD-managed from hand-applied resources at a glance.
- `08-external-dns-annotation-on-services.yaml` — when an LB Service in
  ingress-nginx is annotated for external-dns, the hostname must match the
  cluster's domain. Catches accidental cross-environment hostnames.
