# Spec: `terraform-data-hash-all-deps`

- **ID**: SKILL-SPEC-9914e10966
- **Source retrospective**: ../2026-05-25-70.md

## Intent

When authoring or editing a Terraform `terraform_data` resource with a `local-exec` provisioner that runs `kubectl apply`, `aws cli` invocations, or any other command whose effect depends on inline manifest or command body content, ensure every body component is hashed into `triggers_replace`. Provides a checklist for extracting inline bodies into named `local` values, computing their `sha256` (or `filesha1` for file-backed sources), and adding a versioned sentinel for command-body-only changes that fall outside the hashed locals.

## Trigger

**Direct trigger phrases**: "hash my terraform_data triggers", "audit triggers_replace", "fix the no-op apply", "my terraform apply says 0 added but I edited the manifest".

**Proactive triggers** (offer without being asked):

- The agent is editing the body of a `local-exec` `command = <<-EOT … EOT` heredoc inside a `terraform_data` resource.
- The agent is about to commit a change to a `.tf` file whose immediate context contains `resource "terraform_data"` and `provisioner "local-exec"`.
- A `terraform apply` log shows `Apply complete! Resources: 0 added, 0 changed, 0 destroyed` after a deliberate manifest or command edit.

**Negative triggers** (do NOT activate):

- Editing a `kubernetes_manifest` resource (different mechanism — the K8s provider handles its own diff).
- Editing a `helm_release` resource (`values` and `set` blocks are already diff-tracked).

## Inputs

- A `.tf` file (typically `terraform/management/helm.tf` in this repo, but the skill is repo-agnostic).
- Optionally, a specific resource name (e.g. `terraform_data.crossplane_aws_provider`) to scope the audit.
- The current Terraform working directory (to enable `terraform plan` for validation).

## Outputs

- An edited `.tf` file with:
  - An inline manifest body extracted into a named `local` (e.g. `local.<resource_name>_manifest`).
  - `triggers_replace` extended to include `sha256(local.<that_local>)` for each extracted body.
  - For command-body-only changes that aren't captured by an extracted local (e.g., shell flow control around the templated body), a versioned sentinel string like `"provisioner-command-v2"` documented in a comment.
- A short summary printed to chat naming each `terraform_data` resource audited, whether it was already correctly hashed, and what was added.

## Workflow

1. **Locate `terraform_data` resources with `local-exec`** in the target file:
   ```bash
   awk '/^resource "terraform_data"/,/^}/' <path> | grep -B2 'local-exec'
   ```
2. **For each such resource**, inspect its `triggers_replace` list:
   - If `triggers_replace` is absent → flag as needing replacement triggers.
   - If `triggers_replace` only contains scalar inputs (string variables, module outputs, version strings), proceed to step 3.
   - If `triggers_replace` already contains a `sha256(local.x)` or `filesha1("path")` that covers the relevant body → no action needed.
3. **Extract the inline manifest body** into a named `local`. Place the `locals { … }` block immediately above the `terraform_data` resource for locality. Use a heredoc with `<<-MANIFEST` so leading whitespace is stripped consistently. Reference the local from the `local-exec` command with `${local.<name>}`. Preserve any `${var.x}` / `${module.x.y}` interpolations inside the local — they evaluate at the local-expression layer, not the heredoc layer.
4. **Add `sha256(local.<name>)`** to `triggers_replace`. If a command-body element (loops, conditionals, extra `kubectl` calls) lives outside the local, add a `"<resource_name>-command-v<N>"` sentinel string to `triggers_replace` and bump `N` whenever that command body changes. Document the sentinel with a one-line comment naming what it covers.
5. **Validate** by running `terraform plan` (if available) and confirming the plan shows `must be replaced` for the resource, with the trigger diff listing the hash change. If plan is unavailable in the sandbox, at minimum `terraform fmt -check` (or visual inspection) to confirm syntax.
6. **Commit** the change with a message naming the silent-no-op symptom: "fix(terraform): hash inline body into triggers_replace so X actually applies".

## Concrete examples

### Example 1 — extracting a manifest into a local (from PR #67)

**Before** (helm.tf):
```hcl
resource "terraform_data" "crossplane_aws_provider" {
  triggers_replace = [
    module.irsa_crossplane.iam_role_arn,
    var.crossplane_provider_family_aws_version,
  ]
  provisioner "local-exec" {
    command = <<-EOT
      kubectl apply -f - <<'MANIFEST'
      apiVersion: pkg.crossplane.io/v1beta1
      kind: DeploymentRuntimeConfig
      …
      MANIFEST
    EOT
  }
}
```

A manifest-body edit (e.g. adding `metadata.name: upbound-provider-family-aws`) is invisible to Terraform — the next apply reports `0 added, 0 changed, 0 destroyed`.

**After**:
```hcl
locals {
  crossplane_aws_provider_manifest = <<-MANIFEST
    apiVersion: pkg.crossplane.io/v1beta1
    kind: DeploymentRuntimeConfig
    …
    MANIFEST
}

resource "terraform_data" "crossplane_aws_provider" {
  triggers_replace = [
    module.irsa_crossplane.iam_role_arn,
    var.crossplane_provider_family_aws_version,
    sha256(local.crossplane_aws_provider_manifest),
  ]
  provisioner "local-exec" {
    command = <<-EOT
      kubectl apply -f - <<'MANIFEST'
${local.crossplane_aws_provider_manifest}
MANIFEST
    EOT
  }
}
```

### Example 2 — command-body sentinel (from PR #68)

A later edit adds `kubectl delete deploy ...` *after* the kubectl apply, inside the `local-exec` command but outside the manifest local. The sha256 of the local doesn't change. Without a sentinel, the apply silently no-ops.

**Fix**: add a sentinel string to `triggers_replace`:

```hcl
  triggers_replace = [
    module.irsa_crossplane.iam_role_arn,
    var.crossplane_provider_family_aws_version,
    sha256(local.crossplane_aws_provider_manifest),
    # Bump when the local-exec command body changes — the sha256 above
    # only covers the manifest local. v2: added rebuild of the
    # provider Deployment after the apply.
    "provisioner-command-v2",
  ]
```

Future command-body edits bump the version: `v2` → `v3` → … . The comment block documents what changed at each bump.

## Anti-patterns

- **Listing only the templated inputs** (IAM role ARN, version variables). These cover the inputs, not the body — body-only edits no-op silently.
- **Hashing the whole `command` string with `sha256(self.command)` or similar.** HCL doesn't support `self` in this context; the local-extraction is the supported workaround.
- **Putting the sentinel in a comment instead of in `triggers_replace`.** Comments don't trigger replacement. The sentinel MUST be a string literal in the list.
- **Renaming the local after the first apply without bumping the sentinel.** A rename without a body change might still produce a hash change (depending on the hash algorithm's stability) but it's brittle — bump the sentinel explicitly.

## Acceptance criteria

1. Every `terraform_data` resource with a `local-exec` provisioner in the target file either (a) has its body in a named local and `sha256(local.<name>)` in `triggers_replace`, OR (b) uses `filesha1("path")` for a file-backed body, OR (c) has been explicitly audited and documented as "no body-content dependency" with a code comment.
2. A small body-only edit (e.g. adding whitespace, changing a label value) triggers `must be replaced` in the next `terraform plan`.
3. The pattern matches the convention already established by `terraform_data.argocd_bootstrap` in `terraform/management/helm.tf:360–363`.
4. The skill's own changes pass `terraform fmt`.

## Files this skill creates / modifies

- `terraform/management/helm.tf` (or analogous paths) — the audited `.tf` file. Each touched resource picks up a `locals { … }` block above it, an extended `triggers_replace` list, and (when needed) a command-body sentinel string.
- No new files created; no new tests authored (the skill validates via `terraform plan` directly).
