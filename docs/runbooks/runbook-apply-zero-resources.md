# Runbook: Apply complete: 0 added — silent no-op class

Brainstorm ID: A4-013. Pairs with SPEC-B3 for defense in depth.

This runbook documents the `terraform_data` silent no-op bug class,
the `triggers_replace` hash-the-manifest pattern that prevents it, and
the step-by-step recovery procedure when a manifests-only edit is found
to have no-op'd. It applies to both agents and human operators.

Three independent instances of this bug occurred in a single session
(PRs #66, #67, #68). Each cost approximately six minutes of
dispatch-and-diagnosis time. The grounding incident is PR #67, terraform-test
run 26354235231.

---

## Symptom

The apply log reports:

```
Apply complete! Resources: 0 added, 0 changed, 0 destroyed.
```

The plan that preceded it reported:

```
No changes. Your infrastructure matches the configuration.
```

The cluster state does not reflect the manifest edit. The change appeared
to succeed but nothing actually changed on the cluster.

---

## Confirm the no-op

Re-run plan and grep the output:

```bash
terraform -chdir=terraform/management plan -var-file=<vars> 2>&1 \
  | grep -E "No changes|Plan:"
```

If the output contains `No changes.` after a manifest body was edited,
the apply was a no-op regardless of its zero exit code. Terraform has
nothing to do because it cannot see the dependency it would need to fire
the replace-trigger.

A compliant plan that detected the change would read `Plan: 1 to add`
(a `terraform_data` destroy-recreate counts as one resource added).

---

## Root cause

`terraform_data` re-executes its provisioner only when one of the values
in `triggers_replace` changes between plan runs. If `triggers_replace`
lists only IAM role ARNs and chart version variables, a manifest-body
edit changes none of those values. Terraform computes no diff, produces
`No changes.`, exits zero, and logs `Apply complete! Resources: 0 added`.

The `kubectl apply` inside the provisioner is never invoked. The cluster
never sees the new manifest.

Reference: PR #67, terraform-test run 26354235231. The missing dependency
was `sha256(local.crossplane_aws_provider_manifest)`. Adding that hash
to `triggers_replace` caused Terraform to detect the manifest change,
destroy-and-recreate the `terraform_data` resource, and re-run the
provisioner.

SPEC-B3 lint prevents this class for `local.*_manifest` references. It
does not cover all three dependency classes listed below; those remain
the operator's responsibility.

---

## Fix pattern

There are three dependency classes that must appear in `triggers_replace`:

```hcl
resource "terraform_data" "crossplane_aws_provider" {
  triggers_replace = [
    module.irsa_crossplane.iam_role_arn,              # templated input
    var.crossplane_provider_family_aws_version,        # templated input
    sha256(local.crossplane_aws_provider_manifest),    # 1. manifest body (inline)
    # filesha1("path/to/file.yaml")                    # 2. file-backed manifest body
    "provisioner-command-v2",                          # 3. command-body sentinel
  ]
}
```

### Class 1: inline manifest body

When the manifest is assembled in a `local` variable (the common pattern),
hash the local:

```hcl
sha256(local.crossplane_aws_provider_manifest)
```

The SPEC-B3 lint asserts that every `local.*_manifest` reference in
`triggers_replace` matches this pattern. Run it before pushing:

```bash
bash tests/unit/test_terraform_data_hashes_manifest.sh
```

### Class 2: file-backed manifest body

When the manifest is read from a file (e.g. via `file()` or passed as
a provisioner argument path), use:

```hcl
filesha1("path/to/file.yaml")
```

This is outside SPEC-B3 scope; it is a manual responsibility.

### Class 3: command-body sentinel

When the provisioner's command text itself is the thing that changed
(not just a templated value), add a version string sentinel:

```hcl
"provisioner-command-v2"
```

Increment the suffix (v2, v3, ...) whenever the command block changes in a
way that is not captured by the other trigger values. PR #68 introduced
`"provisioner-command-v2"` for exactly this class.

Canonical example: `terraform_data.argocd_bootstrap` in
`terraform/management/helm.tf` lines 360-363.

Note: if `null_resource` is reintroduced (the repo has migrated off it
as of 2026-05-25), apply the same three-class reasoning to its
`triggers` block.

---

## Verify the fix landed

Before apply, confirm the plan shows real work:

```bash
terraform -chdir=terraform/management plan -var-file=<vars> 2>&1 \
  | grep -E "Plan:|No changes"
# Expected: "Plan: 1 to add" — not "No changes."
```

After apply, confirm the cluster-side object changed:

```bash
kubectl -n crossplane-system get deploy \
  -l pkg.crossplane.io/provider=provider-family-aws \
  -o jsonpath='{.items[0].spec.template.spec.serviceAccountName}'
# Expected: upbound-provider-family-aws (not a hash-suffixed form)
```

For other manifests, inspect the specific resource that the provisioner
creates or modifies. The apply log alone is not sufficient evidence that
the cluster received the change.

---

## SPEC-B3 lint

Run before pushing any `terraform_data` change:

```bash
bash tests/unit/test_terraform_data_hashes_manifest.sh
```

The lint catches every `local.*_manifest` value that is referenced in a
`terraform_data` block but not hashed in `triggers_replace`. It does not
cover file-backed manifests (class 2) or command-body-only changes
(class 3). Those remain manual responsibilities documented in the "Fix
pattern" section above.

If the lint returns exit 0 and you still observe `Apply complete! Resources: 0 added`
after a manifest edit, check classes 2 and 3 before debugging elsewhere.

---

## Recovery checklist

When a silent no-op is discovered after a merge:

- [ ] Re-run plan. Confirm `No changes.` is the output.
- [ ] Identify which `terraform_data` resource owns the manifest.
- [ ] Check its `triggers_replace`. Determine which class (1/2/3) is missing.
- [ ] Add the missing hash or sentinel.
- [ ] Run `bash tests/unit/test_terraform_data_hashes_manifest.sh` (catches class 1).
- [ ] Re-run plan. Confirm `Plan: 1 to add`.
- [ ] Apply. Confirm `Apply complete! Resources: 1 added`.
- [ ] Verify the cluster-side object reflects the intended change.
- [ ] Open a PR with the fix and the test that would have caught the miss.

---

## Related reading

- `ai/handoff.md` Critical behavioral rules table: "Zero changes after a
  manifest edit = `triggers_replace` missing a hash. See
  `docs/runbooks/runbook-apply-zero-resources.md`."
- SPEC-B3: the static lint that covers class 1 (`local.*_manifest`)
  automatically.
- `retrospective/2026-05-25-70.md` lines 55-57 and 103-109: the three
  independent silent no-op instances that motivated this runbook.
