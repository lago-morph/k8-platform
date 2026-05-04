# Failure Taxonomy

Match the workflow log against the symptom, then apply the listed fix. The
"Auto?" column says whether the fix should be attempted without user input.

| Symptom (in logs) | Category | Where to fix | Fix recipe | Auto? |
|---|---|---|---|---|
| `Error: Failed to query available provider packages` / `not found in any of the providers` | provider-version | `versions.tf` | Loosen or update the version constraint to one Terraform Registry actually publishes | yes |
| `Error: Unsupported argument` / `Invalid block` / `Argument or block definition required` | tf-syntax | the named `.tf` file | Edit the offending block per the error's `on <file> line N` pointer | yes |
| `Error: Inconsistent dependency lock file` | lockfile-drift | `.terraform.lock.hcl` (per module) | Delete the offending lock file; CI's `terraform init -upgrade` regenerates it. Only do this if you intentionally bumped a provider version | yes |
| `AccessDenied`, `is not authorized to perform: <action>` from AWS | iam-permission | `terraform/management/irsa.tf` (or wherever the role's policy doc lives) | Add the missing action to the policy. Confirm scope is reasonable before pushing | yes (with care) |
| `ResourceAlreadyExists`, `... already in use`, `BucketAlreadyOwnedByYou` (after init) | aws-conflict | usually nothing in code | Investigate before touching code — likely orphan resources from a prior apply that wasn't destroyed. Surface to user | no — diagnose |
| `Error: Required variable not set` / empty `${{ secrets.X }}` / `Could not find provider <secret>` | missing-secret | repo Settings → Secrets | Cannot fix from code. Escalate immediately | no — escalate |
| `Error acquiring the state lock` / `ConditionalCheckFailedException` on DynamoDB | state-lock | none initially | Wait 60s and retry. If still locked after 2 retries, surface to user before any `force-unlock` | no — escalate after wait |
| `BucketAlreadyOwnedByYou` during state backend bootstrap step | benign-init | none | Idempotent on re-run; ignore. If the workflow then fails downstream, classify by the downstream error | yes (no action) |
| `Error: timeout while waiting for state to become 'ACTIVE'` (EKS, RDS, etc.) | aws-slow | none initially | Re-run the workflow once. If it times out twice, surface to user — may be a sandbox region issue | no — escalate after retry |
| `failed to install provider` / `checksum mismatch` | provider-checksum | `.terraform.lock.hcl` | Delete the lock file; let CI re-init. Only safe when you trust the registry | yes |
| `Error: failed to refresh state: ... not found` | state-drift | none in code | Resource was deleted out-of-band. Surface to user — they likely need to `terraform import` or accept the destroy plan | no — escalate |

## How to pick

1. Skim the last ~50 lines of the failed step's log for the first `Error:`
   line. Earlier errors usually cause later ones.
2. Match against the table above. If multiple match, pick the most specific.
3. If nothing matches: do not invent a fix. Add a row to this taxonomy as
   part of the escalation report so the next failure has a recipe.
