# 12 — Impact trace: Terraform infrastructure + IRSA + ProviderConfig

**Author:** sonnet impact-tracer
**Scope:** terraform/ + the manifest heredocs terraform produces

---

## Infra impact matrix

| File / block | What it provisions | v2 breaks | Effect after PR #98 |
|---|---|---|---|
| `terraform/management/variables.tf` — `crossplane_provider_family_aws_version` | Version pin for provider-family-aws package | `VERSION-PIN-V1` — PR #98 already bumped to `v2.5.4` | `APPLY-OK-NOOP` (pin is correct post-bump) |
| `terraform/management/variables.tf` — `crossplane_provider_aws_secretsmanager_version` | Version pin for provider-aws-secretsmanager package | `VERSION-PIN-V1` — PR #98 already bumped to `v2.5.4` | `APPLY-OK-NOOP` (pin is correct post-bump) |
| `terraform/management/variables.tf` — `crossplane_function_patch_and_transform_version` | Version pin for function-patch-and-transform | `VERSION-PIN-V1` — PR #98 already bumped to `v0.10.6` | `APPLY-OK-NOOP` (pin is correct post-bump) |
| `terraform/management/variables.tf` — `crossplane_version` | Crossplane Helm chart version | None — already `2.3.0` (v2) | `APPLY-OK-NOOP` |
| `terraform/management/helm.tf` — `helm_release.crossplane` | Installs Crossplane Helm chart v2.3.0 with beta flags disabled | None | `APPLY-OK-NOOP` |
| `terraform/management/helm.tf` — `locals.crossplane_aws_provider_manifest` (L174–206) | Heredoc producing `DeploymentRuntimeConfig` + `Provider` YAML applied via local-exec | `IRSA-SA-NAME`, `DEPLOYMENT-RUNTIME-CONFIG` | `APPLY-OK-DRIFT` |
| `terraform/management/helm.tf` — `terraform_data.crossplane_aws_provider` (L209–249) | local-exec: kubectl apply of the provider manifest heredoc + delete deploy hack | `IRSA-SA-NAME`, `PROVIDER-MANIFEST-V1` | `APPLY-OK-DRIFT` |
| `terraform/management/helm.tf` — `terraform_data.crossplane_function_patch_and_transform` (L255–278) | Installs function-patch-and-transform `Function` package via local-exec | None — `apiVersion: pkg.crossplane.io/v1beta1` `kind: Function` is unchanged in v2 | `APPLY-OK-NOOP` |
| `terraform/management/helm.tf` — `terraform_data.crossplane_provider_aws_secretsmanager` (L284–307) | Installs provider-aws-secretsmanager `Provider` package via local-exec | None — `apiVersion: pkg.crossplane.io/v1` `kind: Provider` is unchanged | `APPLY-OK-NOOP` |
| `terraform/management/helm.tf` — `terraform_data.argocd_bootstrap` | Applies ArgoCD bootstrap Application; ArgoCD then syncs crossplane/ manifests | None in terraform itself — breakage is in the synced manifests (see doc 11) | `APPLY-OK-DRIFT` |
| `terraform/management/irsa.tf` — `module.irsa_crossplane` (L89–105) | IRSA role trust policy pinned to SA `crossplane-system:upbound-provider-family-aws` | `IRSA-SA-NAME` | `APPLY-OK-DRIFT` |
| `terraform/management/irsa.tf` — `aws_iam_policy.crossplane_aws` (L33–87) | IAM policy: EKS, EC2, IAM, SecretsManager permissions for Crossplane provider | None | `APPLY-OK-NOOP` |
| `terraform/management/irsa.tf` — `module.irsa_eso` (L129–145) | IRSA role for ESO SA `external-secrets:external-secrets` | None — ESO v1 name unchanged | `APPLY-OK-NOOP` |
| `terraform/management/irsa.tf` — `module.irsa_external_dns` (L185–201) | IRSA role for ExternalDNS SA `external-dns:external-dns` | None | `APPLY-OK-NOOP` |
| `terraform/management/irsa.tf` — `module.irsa_argocd` (L15–29) | IRSA role for ArgoCD SAs `argocd:argocd-server` + `argocd:argocd-application-controller` | None | `APPLY-OK-NOOP` |
| `terraform/management/eks.tf` — `module.eks` | EKS cluster + OIDC provider | None | `APPLY-OK-NOOP` |
| `terraform/management/main.tf` | Remote state read, caller identity | None | `APPLY-OK-NOOP` |
| `terraform/management/outputs.tf` | Cluster name, endpoint, OIDC ARN, IRSA ARNs | None | `APPLY-OK-NOOP` |
| `terraform/management/versions.tf` | Provider version constraints, S3 backend | None | `APPLY-OK-NOOP` |
| `terraform/management/subnets.tf` | Management cluster subnets and route tables | None | `APPLY-OK-NOOP` |
| `terraform/management/terraform.tfvars.example` | Example variable file (not applied by CI) | Stale: still shows `crossplane_version = "2.0.1"` and `crossplane_provider_family_aws_version = "v1.12.0"` — documentation drift only | `APPLY-OK-NOOP` (not read by CI) |
| `terraform/base/*.tf` | VPC, ACM cert, Route53, Cognito — no Crossplane content | None | `APPLY-OK-NOOP` |

---

## Per-block detail (only blocks with at least one break)

### terraform/management/helm.tf — `locals.crossplane_aws_provider_manifest` (L174–206)

**Breaks:** `IRSA-SA-NAME`, `DEPLOYMENT-RUNTIME-CONFIG`

The heredoc produces two k8s manifests applied verbatim via `kubectl apply`:

**Document 1 — DeploymentRuntimeConfig (L175–195):**
```yaml
apiVersion: pkg.crossplane.io/v1beta1
kind: DeploymentRuntimeConfig
metadata:
  name: aws-provider-config
spec:
  serviceAccountTemplate:
    metadata:
      name: upbound-provider-family-aws          # ← IRSA-SA-NAME
      annotations:
        eks.amazonaws.com/role-arn: "<irsa_arn>"
```

- **L192: `name: upbound-provider-family-aws`** — The v1 provider-family-aws package registered itself under this exact SA name; the `DeploymentRuntimeConfig` was added (PR #66, phase-2-diagnose run 26355033199) to force the SA name so the IRSA OIDC sub-claim (`system:serviceaccount:crossplane-system:upbound-provider-family-aws`) matches the IRSA trust policy in `irsa.tf:98`. The v2.5.4 package's default SA name is **unknown** from static analysis of this repo alone — it may use the same name or a different convention. If v2 uses a different default SA name and the `DeploymentRuntimeConfig` pin overrides it to `upbound-provider-family-aws`, IRSA authentication will still work _if_ the override is applied first. However, if v2 packages no longer honour `serviceAccountTemplate.metadata.name` in the same way, or if the DRC applies after the pod is already running, the mismatch will silently fail (`AssumeRoleWithWebIdentity` rejects the token because the OIDC sub-claim won't match).

**Document 2 — Provider (L196–206):**
```yaml
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-family-aws
spec:
  package: "xpkg.upbound.io/upbound/provider-family-aws:v2.5.4"
  runtimeConfigRef:
    apiVersion: pkg.crossplane.io/v1beta1
    kind: DeploymentRuntimeConfig
    name: aws-provider-config
```

- `pkg.crossplane.io/v1` `kind: Provider` and `runtimeConfigRef` pointing to a `DeploymentRuntimeConfig` are both v2-compatible API patterns. No break here in the manifest structure itself.
- **No `ProviderConfig` (`kind: ProviderConfig` / `kind: ClusterProviderConfig`) is applied by Terraform or any other mechanism in this repo.** The `providerConfigRef: name: default` in both Compositions refers to a ProviderConfig named `default` that must be created by an operator or by the chainsaw test setup (`tests/chainsaw/run.sh:229–241`). In a fresh AWS account `terraform apply` leaves no ProviderConfig on the cluster; the Compositions will reconcile but every MR will fail with "ProviderConfig not found: default" until a ProviderConfig is manually applied. This was pre-existing before v2; the v2 migration adds the requirement that the ProviderConfig manifest also carry `kind:` in `providerConfigRef` (see doc 11 — `PROVIDER-CONFIG-MISSING-KIND`). The **terraform layer has no role in creating the ProviderConfig** and no new break is introduced here by the version bump alone. Documented for completeness.

**Effect:** `APPLY-OK-DRIFT` — terraform apply succeeds (the `kubectl apply` of the DRC + Provider manifests is syntactically valid). Post-apply drift: if v2 changes the SA name convention or the DRC pin is no longer sufficient, the provider pod will run under a SA whose OIDC sub-claim does not match the IRSA trust policy, and every AWS API call from the provider will return `AccessDenied`. This is the single biggest blocker for Crossplane to function post-apply.

---

### terraform/management/helm.tf — `terraform_data.crossplane_aws_provider` (L209–249)

**Breaks:** `IRSA-SA-NAME`, `PROVIDER-MANIFEST-V1`

```hcl
triggers_replace = [
  module.irsa_crossplane.iam_role_arn,
  var.crossplane_provider_family_aws_version,   # ← changes from v1.12.0 to v2.5.4 (PR #98)
  sha256(local.crossplane_aws_provider_manifest),
  "provisioner-command-v2",
]
```

- The `triggers_replace` list includes `var.crossplane_provider_family_aws_version`. When PR #98 merges, the variable changes from `v1.12.0` to `v2.5.4`, which changes the `sha256(local.crossplane_aws_provider_manifest)` value (because the package URL changes). Both trigger values change → the resource is marked for replacement → the `local-exec` provisioner re-runs → the DeploymentRuntimeConfig + Provider are re-applied. This is correct behaviour; the re-apply happens automatically.

- **L242–244 (the `kubectl delete deploy` hack):**
  ```bash
  KUBECONFIG=/tmp/k8-platform-kubeconfig kubectl -n crossplane-system \
    delete deploy -l "pkg.crossplane.io/provider=provider-family-aws" \
    --ignore-not-found --wait=false || true
  ```
  This deletes the provider Deployment after every DRC/Provider apply, forcing Crossplane to recreate it from the current DRC. Under v2.3.0 this workaround may still be needed (the comment says it was fixed in "2.2"; however the workaround tag `"provisioner-command-v2"` suggests it was already evaluated). The label `pkg.crossplane.io/provider=provider-family-aws` matches on the provider name — this label convention is stable across v1/v2. No v2 break here; the label selector remains valid.

- **KUBECONFIG lifecycle:** Both `local-exec` blocks write to `/tmp/k8-platform-kubeconfig`. This path is shared across all terraform_data resources in this file. No namespace or version dependency on the kubeconfig file itself — it is a cluster credential, not a Crossplane version artifact. No `KUBECONFIG-LIFECYCLE` break.

**Effect:** `APPLY-OK-DRIFT` — for the same IRSA-SA-NAME reason as the locals block above.

---

### terraform/management/irsa.tf — `module.irsa_crossplane` (L89–105)

**Breaks:** `IRSA-SA-NAME`

```hcl
module "irsa_crossplane" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${var.cluster_name}-crossplane"

  oidc_providers = {
    main = {
      provider_arn               = local.oidc_provider_arn
      namespace_service_accounts = ["crossplane-system:upbound-provider-family-aws"]  # ← IRSA-SA-NAME
    }
  }
  ...
}
```

- **L98: `"crossplane-system:upbound-provider-family-aws"`** — This is the IAM role trust policy condition:
  ```
  StringEquals:
    oidc.eks.<region>.amazonaws.com/<cluster>:sub:
      system:serviceaccount:crossplane-system:upbound-provider-family-aws
  ```
  The trust policy is created at `terraform apply` time and is immutable without re-running terraform. If the v2.5.4 package creates its provider pod under a different SA name (e.g., a hash-suffixed default), and the `DeploymentRuntimeConfig` override in `helm.tf` fails to pin it to `upbound-provider-family-aws`, the OIDC token presented to AWS STS will have sub-claim `system:serviceaccount:crossplane-system:<different-name>` → `AssumeRoleWithWebIdentity` → `Access denied`. All Crossplane-managed AWS resources will fail to reconcile.

- If the `DeploymentRuntimeConfig` pin continues to work correctly in v2 (i.e., v2 still honours `serviceAccountTemplate.metadata.name`), this trust policy remains valid and no terraform change is needed. The risk is that v2 changes the DRC interface or the SA naming logic in a way that makes the pin ineffective.

**Effect:** `APPLY-OK-DRIFT` — terraform apply succeeds (IAM role is created/updated with the same trust policy). The drift is operational: if the SA name pin fails, the Crossplane provider cannot authenticate to AWS.

---

### terraform/management/terraform.tfvars.example (documentation drift)

Not applied by CI; included for completeness.

- **L23: `crossplane_version = "2.0.1"`** — stale; actual default in `variables.tf` is `2.3.0`.
- **L24: `crossplane_provider_family_aws_version = "v1.12.0"`** — stale; PR #98 bumps the default in `variables.tf` to `v2.5.4`.

No functional break; this file is not read by the CI pipeline. It misleads developers doing local runs.

**Effect:** `APPLY-OK-NOOP` (not processed by terraform in CI).

---

## IRSA-SA-name pinning table

| IRSA role (Terraform module) | Pinned SA(s) | v1 or v2? | Risk if SA name changes |
|---|---|---|---|
| `module.irsa_crossplane` (`irsa.tf:89`) | `crossplane-system:upbound-provider-family-aws` | v1 convention (was the v1 package's stable SA name; pinned via DRC to survive hash-suffix default) | **HIGH** — if v2 package + DRC override produces a different actual SA name, IRSA trust fails; all Crossplane AWS calls → AccessDenied |
| `module.irsa_eso` (`irsa.tf:129`) | `external-secrets:external-secrets` | ESO-stable (not provider-version-dependent) | None — ESO SA name is set by ESO Helm chart, not Crossplane |
| `module.irsa_external_dns` (`irsa.tf:185`) | `external-dns:external-dns` | stable | None |
| `module.irsa_argocd` (`irsa.tf:15`) | `argocd:argocd-server`, `argocd:argocd-application-controller` | stable | None |

**Total IRSA-SA-name pins at risk from v2 provider change:** 1 (`crossplane-system:upbound-provider-family-aws`).

---

## Cross-cutting observations

### ProviderConfig generation paths

**Terraform generates zero ProviderConfig manifests.** The `default` ProviderConfig that both Compositions reference via `providerConfigRef: name: default` (platform-secret.yaml:63, platform-cluster.yaml:85/112/147/174/195/216/253/312) is not created by any terraform resource, ArgoCD Application, or Crossplane manifest in this repo. It is created only in the chainsaw test harness (`tests/chainsaw/run.sh:229–241`) with `apiVersion: aws.upbound.io/v1beta1` (v1 group). On a real cluster after `terraform apply`, a ProviderConfig named `default` must be applied manually before any Composition can reconcile. This is a pre-existing gap. Post-v2-migration it becomes a double gap: the ProviderConfig itself needs to use the v2 API group (`aws.m.upbound.io/v1beta1`) and the Compositions' `providerConfigRef` must add `kind: ClusterProviderConfig`.

### Hardcoded v1 API groups inside terraform

No terraform file hardcodes a v1 API group string (e.g., `aws.upbound.io`). All Crossplane API group strings (`pkg.crossplane.io/v1`, `pkg.crossplane.io/v1beta1`) in the heredoc are package manager APIs — these are stable and unchanged between Crossplane v1 and v2. The v1→v2 API group change (`*.aws.upbound.io` → `*.aws.m.upbound.io`) affects only provider CRD groups, which appear exclusively in the Composition and XRD manifests (covered in doc 11).

### terraform-test.yml workflow implications

The workflow dispatches `[management] apply` then `[management] verify`. Post PR #98 merge:

1. **`terraform apply` — succeeds.** All terraform resources create/update without error. The version bump in `variables.tf` causes `terraform_data.crossplane_aws_provider` to re-apply (triggers_replace fires on the version string change) → DRC + Provider re-applied via kubectl → provider Deployment deleted and recreated.

2. **Post-apply Crossplane state — degraded.** The v2.5.4 provider package installs successfully. Whether IRSA auth works depends on whether the DRC SA name pin (`upbound-provider-family-aws`) is respected by v2. If it is, the provider authenticates to AWS and is `Healthy=True`. If not, provider pod is `Healthy=True` (package installed) but every MR reconcile returns `AccessDenied`.

3. **`[management] verify` step** — checks that pods in `crossplane-system` are Running (yes, they will be Running regardless of IRSA auth). Does NOT check provider `Healthy` status or attempt to create any MR. The verify step will pass even if IRSA is broken.

4. **ArgoCD sync** (triggered by `argocd_bootstrap` terraform_data, wave -100) — ArgoCD syncs `crossplane/` manifests (XRDs, Compositions) from `main` branch. The v1 manifests on main will be applied. Crossplane v2.3.0 with v2.5.4 provider will reject or mishandle these (see doc 11 for full ADMISSION-REJECT / BLAST analysis). **This is the most visible failure point in the terraform-test.yml run** — the chainsaw `[management] e2e-verify` step that checks XR readiness will time out.

### Single biggest blocker for `terraform apply` to succeed on v2

The `terraform apply` itself completes without error. The blocker for **Crossplane to function** after apply is:

**The IRSA SA name pin.** `irsa.tf:98` hard-codes the OIDC trust condition to `crossplane-system:upbound-provider-family-aws`. The `helm.tf` heredoc pins the SA name via DeploymentRuntimeConfig. If these two sides agree (DRC override is effective in v2), IRSA works and the provider authenticates. If the DRC override is ineffective or the v2 package ignores it, every Crossplane AWS call fails silently with `AccessDenied` — identical to the pre-fix symptom reported in the situation doc (run 26353150253), and indistinguishable from the v1/v2 mismatch bug without looking at provider pod logs.

No terraform change is needed to the IRSA trust policy itself if the `upbound-provider-family-aws` SA name is preserved. The risk is unknown until the v2.5.4 package is tested against the DRC override.
