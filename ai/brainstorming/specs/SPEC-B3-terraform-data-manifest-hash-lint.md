# SPEC-B3 — `test_terraform_data_hashes_manifest.sh`: every manifest-bearing `terraform_data` must hash its manifest in `triggers_replace`

## 1. Summary

Add a static-lint unit test that scans every `terraform_data` resource
under `terraform/*/` and, for each one whose `provisioner` block
references a `local.<name>_manifest` symbol, fails the build unless
that same `local.<name>_manifest` appears inside the resource's
`triggers_replace` argument wrapped in a content hash
(`sha256(...)`, `md5(...)`, or `sha512(...)`). The lint is a
one-shot guard against a specific, already-observed silent-no-op
class — Terraform reporting "Apply complete!" while the cluster
never sees the manifest edit because the trigger only watched the
templated values and not the body.

## 2. Retro pain killed (with cited PRs/bugs)

- **PR #67 — `triggers_replace` miss on
  `terraform_data.crossplane_aws_provider`.** The
  `local.crossplane_aws_provider_manifest` body was edited to pin the
  Crossplane provider's ServiceAccount name
  (`upbound-provider-family-aws`) so the IRSA OIDC `sub` claim would
  match. The Terraform apply on run 26354235231 reported "No changes
  ... Apply complete! 0 added, 0 changed, 0 destroyed" and the
  cluster's Crossplane provider Deployment kept mounting the
  hash-suffixed SA — every ASM Secret MR continued to stall
  `Ready=False` with no `atProvider.arn`, and PlatformSecret claims
  sat Waiting forever. Root cause: the resource's `triggers_replace`
  pair only listed `module.irsa_crossplane.iam_role_arn` and
  `var.crossplane_provider_family_aws_version` — neither value
  changed when the manifest body changed, so Terraform's
  replace-trigger never fired, the provisioner never re-ran, and
  `kubectl apply` was never invoked. Fixed in the post-#67 edit at
  `terraform/management/helm.tf:184-193`:
  ```
  triggers_replace = [
    module.irsa_crossplane.iam_role_arn,
    var.crossplane_provider_family_aws_version,
    sha256(local.crossplane_aws_provider_manifest),   # ← the fix
    "provisioner-command-v2",
  ]
  ```
  This spec makes that line a contract enforced at CI time, so the
  next manifest-bearing `terraform_data` resource (and there will be
  more — see `crossplane_function_patch_and_transform`,
  `crossplane_provider_aws_secretsmanager` which currently inline
  their YAML directly in the heredoc rather than via a `local`) can't
  regress the same bug by omission.

## 3. Out of scope

- **Verifying the hash covers the full manifest body.** The lint
  only checks the *syntactic* presence of `sha256(local.<x>_manifest)`
  inside `triggers_replace`. It does not run Terraform, does not
  evaluate expressions, and does not detect partial concatenations
  (e.g. `sha256(substr(local.foo_manifest, 0, 100))` would pass even
  though it under-covers). The pain killed by PR #67 was total
  absence, not partial coverage; spec-creep into expression analysis
  belongs in a separate spec if it ever bites.
- **`null_resource`.** PR #67's class lives in `terraform_data`
  blocks; the repo has migrated off `null_resource` (which requires
  the deprecated `null` provider). If a `null_resource` is
  reintroduced, a follow-up spec extends this lint.
- **`provisioner` bodies that templat-interpolate cluster state
  without a `local.*_manifest` indirection.** Today every
  manifest-bearing `terraform_data` in the repo either (a) uses a
  named `local.*_manifest` or (b) inlines a static heredoc with no
  references. The lint targets shape (a); shape (b) is handled by
  the `"provisioner-command-v2"` versioning convention already in
  helm.tf line 192 (out of scope for this lint to enforce, would
  need a separate "command-version-bumped" linter).
- **Modules outside `terraform/`.** Crossplane Compositions,
  ArgoCD manifests, Helm values — none are Terraform, none have
  `terraform_data`, none in scope.
- **Hash algorithm policy.** `sha256`/`sha512`/`md5` all pass; this
  spec does not force a choice. The repo's existing convention
  (`sha256` in helm.tf, `sha1`/`filesha1` for file-based hashes) is
  unchanged.

## 4. Files to change / create

Create:

- `tests/unit/test_terraform_data_hashes_manifest.sh` — the lint
  script. Pure bash + `grep`/`awk` over `terraform/*/*.tf`. No new
  binaries required.
- `tests/unit/fixtures/terraform_data_manifest_hash/` — small
  fixture corpus (described in §6) of `.tf` files that the lint is
  pointed at by the test to exercise pass/fail paths. Each fixture
  is a self-contained `.tf` file the lint reads in isolation (the
  test sets a `LINT_TARGET_DIR` env var to point the script at the
  fixture dir, falling back to `terraform/` when unset).

Modify:

- `tests/unit/run.sh` — append a `run_suite
  tests/unit/test_terraform_data_hashes_manifest.sh` line so the
  new test is auto-invoked by the existing entry point (the
  workflow at `.github/workflows/terraform-test.yml` already calls
  `run.sh`, so no workflow edit is needed).
- (No edits to `terraform/management/helm.tf` — the post-#67 fix
  already complies; see §11 for the audit step.)

## 5. Implementation notes

**Parsing approach.** Three candidates were considered:

1. `terraform show -json` (post-init/plan) — most accurate, but
   requires a real `terraform init` against AWS state and is far
   too heavy for a unit-level lint. Rejected.
2. `hcl2json` — clean AST, but adds a binary dependency the
   sandbox doesn't have (handoff §"Session capabilities" lists
   `jq`/`yq`/`kubectl`/`helm` — no `hcl2json`). Rejected to keep
   the test runnable everywhere `bash` is.
3. **Regex over the raw HCL** — chosen. The pattern is narrow and
   stable: `resource "terraform_data" "<name>" {` … `triggers_replace
   = [ … ]` … `provisioner "local-exec" { command = <<-EOT … EOT }`.
   The fragility risk (a future maintainer using exotic HCL syntax)
   is acceptable because the lint runs every push and a false
   negative degrades gracefully into "manually verify".

**Algorithm sketch:**

```
for each .tf file under $LINT_TARGET_DIR (default terraform/):
  split into resource blocks by 'resource "terraform_data"' headers
  for each terraform_data block:
    extract the resource label (the second quoted string)
    capture the triggers_replace = [...] argument (multi-line, brace-aware)
    capture every provisioner { ... } body (multi-line, brace-aware)
    referenced_locals = unique(
        match all 'local\.([a-zA-Z0-9_]+_manifest)\b' in provisioner bodies
    )
    if referenced_locals is empty:
      continue  # nothing to enforce
    for each ref in referenced_locals:
      expected_pattern = '(sha256|sha512|md5)\s*\(\s*local\.' + ref + '\s*\)'
      if expected_pattern not found in triggers_replace argument:
        FAIL with: <file>:<line> resource terraform_data.<label>
                   references local.<ref> in its provisioner but
                   triggers_replace does not hash it.
```

**Handling multiple manifest refs.** A single `terraform_data`
that templates two locals (`local.foo_manifest` and
`local.bar_manifest`) into the same heredoc must hash both. The
lint loops over the set; each unhashed ref is a separate FAIL line.

**Brace-aware capture.** HCL nests `{`/`}` inside heredocs.
Bash-only solution: read the file line-by-line, maintain a
brace-depth counter, but *only count braces outside heredoc
markers* (`<<-EOT … EOT` / `<<-MANIFEST … MANIFEST`). Heredoc
boundaries are easy to detect because Terraform's `<<-?<TAG>`
pattern is on its own line and the closing `<TAG>` is alone on a
line. A 40-line bash helper handles both.

**Allowlist.** Some `terraform_data` resources legitimately have
no manifest indirection — they exist purely to sequence
provisioner steps over templated variables (the
`crossplane_function_patch_and_transform` and
`crossplane_provider_aws_secretsmanager` blocks at
`terraform/management/helm.tf:224` and `:253` inline the YAML
directly inside the heredoc with no `local.*_manifest`
reference). The lint must not flag them. The "no
`local.*_manifest` ref ⇒ skip" rule above handles this
automatically — no static allowlist file needed. If a future
case needs explicit suppression, the convention is a single-line
HCL comment `# lint:terraform_data_hashes_manifest:ignore` on the
resource header line; the lint greps for it before evaluating.
(Document the escape hatch in the test script's header
comment.)

**Output format.** Same as other lints in `tests/unit/`: one
`PASS` or `FAIL` line per resource, with a `── …` section
banner; final `summary` call via `tests/unit/lib/test-helpers.sh`.

## 6. Tests required

Per AGENTS.md §6.1, layer + file + assertion shape:

| Layer | File | Assertion shape |
|---|---|---|
| Unit | `tests/unit/test_terraform_data_hashes_manifest.sh` | Pointed at `tests/unit/fixtures/terraform_data_manifest_hash/pass/`, the lint exits 0 and emits one `PASS` line per fixture resource. |
| Unit | same | Pointed at `tests/unit/fixtures/terraform_data_manifest_hash/fail/`, the lint exits non-zero and emits a `FAIL` line naming the resource + the unhashed `local.*_manifest` symbol. |
| Unit | same | **PR #67 regression fixture** — `fixtures/.../fail/pr67_repro.tf` exactly mirrors the pre-#67 `crossplane_aws_provider` shape: a `local.crossplane_aws_provider_manifest` containing a `DeploymentRuntimeConfig` + `Provider`, a `terraform_data` whose `triggers_replace` lists only the IRSA arn + version, and a `provisioner "local-exec"` whose heredoc interpolates `${local.crossplane_aws_provider_manifest}`. The lint MUST fail on this file. Per AGENTS.md §6.2 TDD: author this fixture and the assertion *before* the lint logic, confirm it fails for the right reason, then implement. |
| Unit | same | **Post-#67 positive fixture** — `fixtures/.../pass/pr67_fixed.tf` is the same shape with `sha256(local.crossplane_aws_provider_manifest)` added to `triggers_replace`. Lint passes. |
| Unit | same | **Multi-manifest fixture** — `fixtures/.../fail/multi_manifest.tf` has one `terraform_data` interpolating two locals (`local.a_manifest`, `local.b_manifest`); `triggers_replace` hashes only `a_manifest`. The lint reports exactly one FAIL line, naming `b_manifest`. |
| Unit | same | **No-manifest fixture** — `fixtures/.../pass/no_manifest.tf` mirrors the `crossplane_function_patch_and_transform` shape (inline heredoc, no `local.*_manifest`). Lint passes silently (no PASS line for it, no FAIL line). |
| Unit | same | **Allowlist comment fixture** — `fixtures/.../pass/ignored.tf` has the unhashed-manifest shape *plus* the `# lint:terraform_data_hashes_manifest:ignore` comment. Lint passes. |
| Unit | same | **Algorithm-tolerance fixture** — `fixtures/.../pass/md5_ok.tf` and `pass/sha512_ok.tf` use `md5(...)` and `sha512(...)` respectively; both pass. A `fixtures/.../fail/plain_ref.tf` lists `local.foo_manifest` in `triggers_replace` *unwrapped* (no hash function); lint fails. |
| Unit | same | **Live-repo smoke** — with `LINT_TARGET_DIR` unset, the lint scans the real `terraform/` tree and exits 0. This is the actual contract; the fixture tests above are guards against the lint itself regressing. |

Per AGENTS.md §6.4 (adversarial-reviewer-of-test-plans): before
authoring the fixtures, dispatch one subagent to review the
fixture set against this question — *"is there any HCL shape in
`terraform/*/*.tf` today that the lint will silently skip or
falsely flag?"* — and add fixtures for any shape the reviewer
surfaces.

## 7. Documentation updates

- `tests/unit/test_terraform_data_hashes_manifest.sh` header
  comment names PR #67 as the originating bug and documents the
  `# lint:terraform_data_hashes_manifest:ignore` escape hatch.
- `ai/handoff.md` — under "Behavioral rule additions" / "Bug
  classes the test suite now catches", add: *"manifest-bearing
  `terraform_data` whose `triggers_replace` doesn't hash the
  manifest body (PR #67 class) is now a unit-test failure."*
- No `AGENTS.md` edit. §6.1 already lists `tests/unit/` as a
  layer; the new test slots in.
- No `ai/testing-guidelines.md` edit unless the adversarial review
  surfaces a new fixture convention worth promoting.
- No `ai/TESTING-PLAN.md` edit beyond crossing the relevant TODO
  item if one is open for this lint.

## 8. Workflow / auto-invocation wiring

`tests/unit/run.sh` is the single entry point invoked by
`.github/workflows/terraform-test.yml` at `(phase=test,
action=test-unit)`. Adding one `run_suite …` line
auto-wires the new lint into every PR check and every
`tests/unit/run.sh` local invocation. No new workflow file, no
new job, no new permissions.

The lint is pure-local: no AWS calls, no `terraform init`, no
network. Runs in <1 s on the current repo. Safe to include in
every push.

## 9. Discoverability for future agents

Three forcing functions:

1. **CI fail-point pinpoints the missing hash.** The `FAIL` line
   names the file, the resource label, and the symbol — e.g.
   `terraform/management/helm.tf:178 terraform_data.crossplane_aws_provider
   references local.crossplane_aws_provider_manifest in its
   provisioner but triggers_replace does not hash it (expected:
   sha256(local.crossplane_aws_provider_manifest))`. A future
   agent reading the CI log gets the fix recipe verbatim.
2. **The PR #67 regression fixture is named for the bug.** A
   future agent grep-ing the repo for `pr67` lands on
   `fixtures/.../fail/pr67_repro.tf` and the SKILL spec it
   anchors, recovering the institutional memory.
3. **Allowlist comment is in-source.** Any `terraform_data` that
   intentionally opts out has the comment on its header line —
   visible in every code-review diff for the resource, no hidden
   config file.

## 10. Verification checklist

Concrete observable checks the agent runs after implementing this
spec:

- [ ] `bash tests/unit/test_terraform_data_hashes_manifest.sh`
  exits 0 with one final `SUMMARY: N passed, 0 failed` line.
- [ ] `bash tests/unit/run.sh` includes the new test in its
  output banner and exits 0.
- [ ] `LINT_TARGET_DIR=tests/unit/fixtures/terraform_data_manifest_hash/fail
  bash tests/unit/test_terraform_data_hashes_manifest.sh` exits
  non-zero and prints a `FAIL` line per fail-fixture resource.
- [ ] `LINT_TARGET_DIR=tests/unit/fixtures/terraform_data_manifest_hash/pass
  bash tests/unit/test_terraform_data_hashes_manifest.sh` exits 0.
- [ ] Mutation test: temporarily comment out the
  `sha256(local.crossplane_aws_provider_manifest)` line in
  `terraform/management/helm.tf`; the live-repo smoke
  invocation now fails with a FAIL line naming
  `crossplane_aws_provider`. Restore the line; the smoke passes
  again.
- [ ] `grep -c terraform_data_hashes_manifest tests/unit/run.sh`
  returns ≥ 1.

## 11. Rollout notes

- Land on branch `spec/top-15-immediate-changes` (no separate
  feature branch needed — the spec is doc-only; the
  implementation lands as a follow-up PR per AGENTS.md §3).
- **Audit step before merging the implementation:** grep the
  current repo for every `resource "terraform_data"` block and
  manually classify each into one of:
  - (a) references a `local.*_manifest` and hashes it ✓ →
    expected: post-#67 `crossplane_aws_provider`.
  - (b) references a `local.*_manifest` and does NOT hash it →
    expected: zero. If non-zero, the lint will fail on land —
    fix those blocks in the same PR as the lint.
  - (c) no `local.*_manifest` reference → expected:
    `kyverno_audit_policies` (file-set hash),
    `crossplane_function_patch_and_transform`,
    `crossplane_provider_aws_secretsmanager`,
    `argocd_bootstrap` (filesha1 over the YAML file). Lint
    skips all of these.
  Today's expected audit result: post-#67 helm.tf is already
  compliant — the lint should land green.
- No Terraform plan/apply changes, no cluster mutations, no
  destructive operations. Pluralsight sandbox constraints
  (us-east-1/us-west-2, t-family small instances, ≤9 EC2, no
  Bedrock/Marketplace) are irrelevant — the lint never calls AWS.
- Backward compatible — adding the lint cannot break an existing
  apply; at worst it fails CI on a non-compliant resource, which
  is the intended behaviour.
- If the lint ever has to be temporarily disabled (e.g. an
  emergency hot-fix needs to land before the fixture is
  authored), the escape hatch is the per-resource comment, not a
  global skip — keep the suite green.

## 12. Estimated effort

**S** — small.

Justification: one bash script (~120 lines including the
brace/heredoc helper), one-line edit to `tests/unit/run.sh`,
~8 short fixture `.tf` files (each 15–40 lines), one
documentation bullet in `ai/handoff.md`. No Terraform changes,
no cluster work, no new workflow files, no new binaries. The
load-bearing pre-work is the adversarial fixture review (§6) to
catch HCL shapes the regex misses — budget half a day for that
plus implementation, total ~4–6 hours.
