# Failure Taxonomy — Crossplane

Match against the failing resource's `status.conditions[].reason` and
`message`, plus `kubectl describe` events. Pick the most specific row.

| Symptom | Category | Where to fix | Fix recipe | Auto? |
|---|---|---|---|---|
| `cannot find ProviderConfig` / `no matches for kind` of a managed resource | provider-not-installed | `terraform/management/helm.tf` (or wherever the provider is installed) | Confirm the `Provider` resource exists and is `Healthy=True`; check the `ProviderConfig` namespace/name matches what the Composition references | yes |
| Provider condition `Healthy=False` reason `InstallPending` for >2 min | provider-install-stuck | n/a initially | `kubectl describe provider/<name>` for events; usually image pull failure or RBAC. Surface to user if not transient | no — diagnose |
| `AccessDenied` / `is not authorized to perform <action>` from AWS provider | iam-permission | `terraform/management/irsa.tf` — Crossplane's role policy doc | Add the missing action; re-apply Terraform via the management module. Confirm scope before pushing | yes (with care; touches tf — hand off to terraform-ci-watch for the apply side) |
| `cannot render composed resources: invalid template` / `cannot patch` | composition-error | `crossplane/compositions/<name>.yaml` | Read the message — it names the patch path or pipeline step that failed. Fix and `kubectl apply -f` | yes |
| Claim `Synced=False` reason `CompositionRevisionNotFound` | composition-revision | usually the Composition; sometimes the Claim's `compositionRef` | Check `kubectl get compositionrevisions`; either the Composition wasn't applied or the Claim references a wrong name | yes |
| Claim stuck `Synced=False` reason `Pending` >5 min, no events | reconcile-loop | almost always a typo | `kubectl describe` — usually a `compositionRef` with a wrong name, or `compositeTypeRef` mismatch with the XRD. Compare claim and XRD literally | yes |
| `the server could not find the requested resource` immediately after XRD apply | xrd-not-installed | n/a (timing) | Wait 30s for CRD registration. If `Established=False` persists on the XRD, fix the XRD spec | yes |
| XRD condition `Established=False` reason `MissingFields` or schema error | xrd-schema | `crossplane/xrds/<name>.yaml` | Edit the OpenAPI schema; re-apply | yes |
| Managed resource `Ready=True` but `aws describe-*` shows missing or wrong state | provider-bug | n/a — do not auto-fix | The provider's observed state diverged from cloud reality. Surface to user with both the k8s status and the AWS describe output. Do NOT delete-and-recreate blindly | no — escalate |
| `LimitExceededException` / `Quota exceeded` from AWS | aws-quota | n/a in code | Surface to user. Sandbox limits are documented in `ai/testing-guidelines.md`. Often "destroy unused stacks" is the answer | no — escalate |
| `EntityAlreadyExists` (IAM role/policy) when creating | aws-conflict | n/a initially | Likely an orphan from a previous failed apply. Investigate before deleting; surface to user with the AWS resource ID | no — diagnose |
| Claim deleted but managed resources stuck `Deleting` | finalizer-stuck | n/a | `kubectl describe` for events — usually a dependency holds the resource (e.g., NodeGroup blocking Cluster delete). Wait, then surface | no — diagnose |

## How to pick

1. Get the conditions JSON for the failing resource (XR or managed) — see
   `readiness-conditions.md` for the one-liner.
2. Get events: `kubectl describe <kind>/<name> -n <ns> | tail -40`.
3. Match against the table. The `reason` field is the strongest signal.
4. If nothing matches: do not invent a fix. Add a row here as part of the
   escalation report.
