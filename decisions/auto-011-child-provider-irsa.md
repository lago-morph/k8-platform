# auto-011 — Child AWS providers have no IRSA identity (phase-3 blocker #3)

**Status:** Option A CHOSEN by the user and IMPLEMENTED in terraform (auto-011);
**pending `management apply-and-verify` to take effect + validate.** This is the
**only** remaining blocker for the platform-cluster provision; the XR is composed
and ready, every other input is correct.

**Implemented (Option A):** `runtimeConfigRef: {kind: DeploymentRuntimeConfig,
name: aws-provider-config}` added to all six child providers — eks/iam/acm/route53
in `terraform/management/crossplane-phase3.tf`, secretsmanager/rds in
`terraform/management/helm.tf` — with manifest-sentinel bumps on each
`triggers_replace` so the apply actually re-runs. They now run under the
IRSA-annotated family SA `upbound-provider-family-aws` (the only subject the
crossplane role trusts), no trust-policy change. Next: `management apply-and-verify`,
then confirm via kube-diagnose that a child provider pod has
`AWS_WEB_IDENTITY_TOKEN_FILE` and the 11 platform-cluster MRs flip Synced=True.
If Crossplane churns on the shared pinned SA, fall back to Option B.

## Symptom

`platform-cluster-claim` synced; the `XPlatformCluster/platform` XR composed all
11 MRs (EKS Cluster/NodeGroup, IAM Roles + RolePolicyAttachments, ACM
Certificate(+Validation), Route53 Record) with **correct spec** (subnets
resolved, external-names set, trust policies right). But after the auto-011
ClusterProviderConfig fix (#161) every MR sits `Synced=False`:

```
ReconcileError: cannot initialize the Terraform plugin SDK async external client:
cannot get terraform setup: cache manager failure: cannot calculate the hash for
the credentials file: token file name cannot be empty
```

No AWS resources are created (CloudTrail: observe calls only, zero creates).

## Root cause (proven via kube-diagnose, run 27076645649)

Each child provider runs its **own** pod under its **own** ServiceAccount, and
**none of those SAs carry the IRSA `eks.amazonaws.com/role-arn` annotation** —
only `upbound-provider-family-aws` does:

```
provider-aws-acm-…             SA provider-aws-acm-…            role-arn= (empty)
provider-aws-eks-…             SA provider-aws-eks-…            role-arn= (empty)
provider-aws-iam-…             SA provider-aws-iam-…            role-arn= (empty)
provider-aws-rds-…             SA provider-aws-rds-…            role-arn= (empty)
provider-aws-route53-…         SA provider-aws-route53-…        role-arn= (empty)
provider-aws-secretsmanager-…  SA provider-aws-secretsmanager-… role-arn= (empty)
upbound-provider-family-aws    SA upbound-provider-family-aws   role-arn=arn:aws:iam::596430611165:role/k8-platform-mgmt-crossplane
```

So child provider pods get no `AWS_WEB_IDENTITY_TOKEN_FILE` → "token file name
cannot be empty". The `aws-provider-config` DeploymentRuntimeConfig (helm.tf)
pins the SA name + role annotation but is referenced **only by the family
Provider** (`runtimeConfigRef`); the child Providers
(`crossplane-phase3.tf` eks/iam/acm/route53, `helm.tf` secretsmanager/rds) carry
**no `runtimeConfigRef`**, so each gets a default, un-annotated SA.

The crossplane IRSA role trust is `StringEquals` on exactly
`system:serviceaccount:crossplane-system:upbound-provider-family-aws`, so a child
running under any other SA subject cannot assume it even if annotated.

> NOTE on history: phase-2 reportedly created an ASM secret at 19:55 today. With
> the current topology the secretsmanager pod also lacks IRSA, so either that
> reconcile used a now-deleted ClusterProviderConfig with different credentials,
> or the provider topology changed. Irrelevant to the fix — the *current* live
> state is unambiguous and is what must be repaired.

## Fix options (pick one; both need a `management apply-and-verify`)

### Option A — shared family SA (minimal, no trust change) — RECOMMENDED to try first
Add to **every** child Provider manifest (crossplane-phase3.tf eks/iam/acm/route53
and helm.tf secretsmanager/rds):
```yaml
spec:
  runtimeConfigRef:
    apiVersion: pkg.crossplane.io/v1beta1
    kind: DeploymentRuntimeConfig
    name: aws-provider-config
```
All provider pods then run as `upbound-provider-family-aws`, which the trust
policy already allows. No irsa.tf change.
- Risk: 7 Deployments referencing a DRC that **pins** `serviceAccountTemplate.
  metadata.name` → they share one SA; verify Crossplane v2.5 doesn't churn on SA
  ownership. If it does, use Option B.

### Option B — per-child SA + wildcard trust (more standard, broader trust)
A new DRC `aws-provider-irsa` whose `serviceAccountTemplate.metadata.annotations`
carries the role-arn but does **not** pin a name; reference it from every
provider. Then broaden the crossplane role trust (irsa.tf, the
`crossplane` IRSA module, line ~140) from `StringEquals` on the single family SA
to also allow `StringLike system:serviceaccount:crossplane-system:provider-aws-*`
(keep the family entry). Each provider keeps its own SA, all annotated.
- Security note (load-bearing): this lets any `provider-aws-*` SA assume the
  powerful crossplane role. Acceptable on this single-tenant mgmt cluster but
  should be a conscious decision; Option A keeps the trust narrow.

## Validation (either option)
1. `terraform-test.yml` phase=management action=apply-and-verify.
2. `kube-diagnose`: every child provider SA shows the role-arn annotation; an eks
   pod has `AWS_WEB_IDENTITY_TOKEN_FILE` set.
3. The 11 platform-cluster MRs flip `Synced=True`; AWS shows the EKS cluster +
   `*.platform.<domain>` ACM cert (the XR is already composed — no re-sync of
   platform-cluster-claim needed, the provider just reconciles the existing MRs).

## Then resume the phase-3 runbook (decisions/auto-009-phase3-live-completion-runbook.md)
cluster Ready → overlay `XPlatformCluster.status.oidcIssuer` onto the XSpokeAccess
XR → `argocd app sync spoke-access` (also needs #162's EnvironmentConfig
`accountId`/`argocdRoleArn` extension applied, i.e. the same management apply) →
register the `platform-spoke` cluster Secret → converge spoke apps → verify
`https://hello.platform.596430611165.realhandsonlabs.net`. Then phase 5 (RDS).
