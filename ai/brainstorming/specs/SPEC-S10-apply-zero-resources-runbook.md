# SPEC-S10 — `runbook-apply-zero-resources.md`: the "Apply complete: 0 added" silent-no-op class

Brainstorm ID: A4-013. Tier S item S10 (`larger-list-preferences.md`). Pairs with SPEC-B3 for defense in depth.

---

## 1. Summary

Create a standalone runbook at
`/home/user/k8-platform/docs/runbooks/runbook-apply-zero-resources.md` that
documents the "Apply complete: 0 added" silent-no-op bug class, the
`triggers_replace` hash-the-manifest pattern that prevents it, and the
step-by-step recovery procedure when a manifests-only edit is found to have
no-op'd. The runbook is written for both agents and human operators: it
explains how to confirm a silent no-op occurred, how to locate the
uncovered dependency, how to apply the fix pattern, and how to verify the
apply actually reached the cluster. It consolidates retro Suggestions 1 and
3 from `retrospective/2026-05-25-70.md` into a single executable checklist.
The smallest concrete artifact is one markdown file plus one unit test that
asserts the file exists and cross-references SPEC-B3. This spec is
documentation-layer (Tier S), effort S; it is the runbook companion to the
static lint described in SPEC-B3, giving agents a human-readable anchor for
a bug class that recurred three independent times in a single session.

---

## 2. Retro pain killed

- **PR #67 — `triggers_replace` miss on `terraform_data.crossplane_aws_provider`.**
  `retrospective/2026-05-25-70.md` lines 55–57: terraform-test run 26354235231
  reported `Apply complete! Resources: 0 added, 0 changed, 0 destroyed` after
  PR #66's manifest edit. Apply ran in 7 seconds; no resource replaced; cluster
  never saw the new SA name. The missing dependency was
  `sha256(local.crossplane_aws_provider_manifest)`. Cost: one extra PR plus a
  full diagnose-and-rediscover cycle.

- **Three independent silent no-ops in one session (PRs #66, #67, #68).**
  `retrospective/2026-05-25-70.md` lines 103–109: three separate misreads of a
  green tool exit as "the change reached the cluster." PR #66's manifest pin
  was a no-op; PR #67's first apply would have no-op'd on command-body changes
  without the `"provisioner-command-v2"` sentinel added in PR #68. Each
  misread cost ~6 minutes of dispatch + diagnosis.

- **`ai/handoff.md` Critical behavioral rules table (line 144).**
  The row "Zero changes after a manifest edit = `triggers_replace` missing a
  hash" was hand-authored post-incident. The runbook formalizes it into an
  actionable checklist retrievable without reading the full handoff.

- **Retro-70 Suggestion 3 (`AGENTS-MD-15a88ad1de`).**
  The proposed AGENTS.md rule states the correct dependency-hash pattern.
  Without a runbook, the rule is text only — no step-by-step recovery
  procedure. The runbook is the actionable companion.

- **SPEC-B3 covers `local.*_manifest`; this runbook covers the full class.**
  The static lint catches the most common shape. Inline heredocs, file-backed
  provisioners, and command-body-only changes (sentinel class) are outside
  SPEC-B3 scope; the runbook documents all three.

---

## 3. Out of scope

- **Implementing the static lint.** The regex-over-HCL lint that catches
  `local.*_manifest` not appearing in `triggers_replace` is SPEC-B3's scope,
  not this spec's. This spec creates only documentation.

- **`null_resource` resources.** SPEC-B3 §3 notes the repo has migrated off
  `null_resource`. If a `null_resource` is reintroduced, the SPEC-B3
  implementing agent handles it. The runbook references `terraform_data` as
  the current resource type; a one-line note instructs readers to apply the
  same reasoning to `null_resource` if it reappears.

- **ArgoCD sync silent no-ops.** `retrospective/2026-05-25-70.md` line 109
  notes the same anti-pattern applies to ArgoCD Synced/Healthy lagging the
  actual workload state. A separate runbook (future A4-012 scope) covers
  ArgoCD out-of-sync diagnosis. This runbook is scoped to Terraform apply.

- **`kubectl apply` controller-reconcile lag.** Also called out in the retro
  as an instance of "apply success is necessary, not sufficient." A
  crossplane-claim-verify skill handles that class; this runbook is
  Terraform-only.

- **Authoring a decision-tree runner.** Brainstorm comment A6→A4-007 proposes
  merging runbooks A4-010–A4-013 into a shared decision-tree format driven by
  A4-059. That refactor is future work; this spec authors the runbook in plain
  markdown without the runner dependency.

### Considered and rejected

- **Embedding the runbook in `docs/operations.md`.**
  `docs/operations.md` is already the "day-to-day operations" guide. Embedding
  a multi-step failure runbook inside a general guide makes it unfindable when
  needed under pressure. A dedicated file under `docs/runbooks/` mirrors the
  pattern proposed by brainstorm IDs A4-010–A4-013 and is preferred.

- **Placing the runbook under `ai/runbooks/`.**
  `ai/` is the design-documents and planning area; `docs/` is the
  human-and-agent-readable operations area. `docs/runbooks/` is the correct
  home for operational procedures that a new agent or human reads when
  something is broken. `ai/brainstorming/` content is brainstorming; `docs/`
  content is actionable reference.

---

## 4. Files to change / create

**Create:**

| Path | What |
|---|---|
| `/home/user/k8-platform/docs/runbooks/runbook-apply-zero-resources.md` | The runbook itself. ~100–150 lines. Decision tree + fix pattern + verification commands. |
| `/home/user/k8-platform/tests/unit/test_runbook_apply_zero_resources.sh` | Unit test asserting the runbook exists, references SPEC-B3, and contains the required sections. |

**Modify:**

| Path | What changes |
|---|---|
| `/home/user/k8-platform/tests/unit/run.sh` | Append one `run_suite tests/unit/test_runbook_apply_zero_resources.sh` line. |
| `/home/user/k8-platform/docs/operations.md` | Add one "Runbooks" section near the bottom with a bullet pointing to `docs/runbooks/runbook-apply-zero-resources.md`. |
| `/home/user/k8-platform/ai/handoff.md` | Update the Critical behavioral rules table row for "Zero changes after a manifest edit" to reference the runbook path. |

No `terraform/`, `crossplane/`, `argocd/`, `.github/workflows/`, or
`policies/` files are touched.

---

## 5. Implementation notes

### 5.1 Runbook content shape

The runbook at
`/home/user/k8-platform/docs/runbooks/runbook-apply-zero-resources.md`
must contain these headed sections in order:

**Symptom** — `Apply complete! Resources: 0 added, 0 changed, 0 destroyed`
after a manifest-body edit; plan says `No changes. Your infrastructure
matches the configuration.`; cluster state does not reflect the edit.

**Confirm the no-op** — re-run plan, grep the apply log:

```bash
terraform -chdir=terraform/management plan -var-file=<vars> 2>&1 \
  | grep -E "No changes|Plan:"
# If "No changes." → the apply was a no-op regardless of exit code.
```

**Root cause** — `terraform_data` re-executes its provisioner only when
`triggers_replace` changes. If `triggers_replace` lists only IAM role ARNs
and chart version variables, a manifest-body edit changes none of them;
Terraform never fires the replace-trigger; `kubectl apply` is never invoked.
Reference: PR #67, terraform-test run 26354235231. SPEC-B3 lint prevents
this class for `local.*_manifest` references.

**Fix pattern** — three dependency classes:

```hcl
resource "terraform_data" "crossplane_aws_provider" {
  triggers_replace = [
    module.irsa_crossplane.iam_role_arn,              # templated input
    var.crossplane_provider_family_aws_version,        # templated input
    sha256(local.crossplane_aws_provider_manifest),    # 1. manifest body
    # filesha1("path/to/file.yaml")                    # 2. file-backed body
    "provisioner-command-v2",                          # 3. command-body sentinel
  ]
}
```

Canonical example: `terraform_data.argocd_bootstrap` in
`/home/user/k8-platform/terraform/management/helm.tf` lines 360–363.

**Verify the fix landed** — before and after apply:

```bash
# Before: plan must show work to do.
# grep for "Plan: 1 to add" — not "No changes."

# After apply: confirm cluster-side object changed.
kubectl -n crossplane-system get deploy \
  -l pkg.crossplane.io/provider=provider-family-aws \
  -o jsonpath='{.items[0].spec.template.spec.serviceAccountName}'
# Expected: upbound-provider-family-aws (not a hash-suffixed form)
```

**SPEC-B3 lint** — run before pushing:

```bash
bash tests/unit/test_terraform_data_hashes_manifest.sh
```

The lint catches `local.*_manifest` not hashed in `triggers_replace`. It
does not cover command-body-only changes (class 3 above); the version
sentinel is the human responsibility for that class.

### 5.2 Runbook format and unit test

Format: no emojis; prose style matching `docs/operations.md`; each command
block self-contained and copy-paste runnable.

`/home/user/k8-platform/tests/unit/test_runbook_apply_zero_resources.sh`
uses `tests/unit/lib/test-helpers.sh` conventions. It makes these assertions:

1. The runbook file exists at `docs/runbooks/runbook-apply-zero-resources.md`.
2. File contains `SPEC-B3` (cross-reference to the lint).
3. File contains `triggers_replace` (core topic present).
4. File contains `sha256` (fix pattern documented).
5. `grep -c "## " ...` returns ≥ 5 (required sections present).

The test is ~35 lines and runs in <1 second (pure file reads).

---

## 6. Tests required

Per AGENTS.md §6.1 — maximal coverage at applicable layers. This is a
documentation-only spec; the applicable layer is unit.

| Layer | File | Assertion |
|---|---|---|
| Unit | `tests/unit/test_runbook_apply_zero_resources.sh` | Runbook file exists at `docs/runbooks/runbook-apply-zero-resources.md`. |
| Unit | same | File contains `SPEC-B3` (cross-reference to lint is present). |
| Unit | same | File contains `triggers_replace` (core topic covered). |
| Unit | same | File contains `sha256` (fix pattern documented). |
| Unit | same | `grep -c "## " docs/runbooks/runbook-apply-zero-resources.md` returns ≥ 5 (required sections present). |

Per AGENTS.md §6.4 (adversarial review): before authoring the unit test,
confirm the test assertions would fail if the runbook were empty or if the
SPEC-B3 cross-reference were removed. Each assertion is a strict `grep -q`
that exits non-zero when the string is absent — tests that pass against an
empty file are useless guards.

Kyverno: N/A — no new cluster-resource pattern.
Integration: N/A — runbook is read-only documentation; no live cluster is
involved in its creation or validation.
Chainsaw: N/A — no XRD or Composition added.

---

## 7. Testing suggestions (unit / integration / e2e)

This spec delivers documentation only; all meaningful coverage is at the
unit layer.

### Unit

Tests live at `tests/unit/test_runbook_apply_zero_resources.sh`. Suggested
cases beyond the §6 gate:

1. **Structural completeness** — assert each required heading (`## Symptom`,
   `## Confirm the no-op`, `## Root cause`, `## Fix pattern`,
   `## Verify the fix landed`) is present.
2. **PR citation** — assert `PR #67` appears (grounding citation).
3. **Run URL citation** — assert `26354235231` appears (the silent no-op run).
4. **Line-count bounds** — `wc -l` returns 80–300 (too short = thin;
   too long = needs splitting).

### Integration

Not applicable. The runbook is a static document with no live cluster
interaction. The unit existence check already covers the file-system layer.

### E2E

Not applicable. No XRD, Composition, or provisioner is added. If brainstorm
A4-059 (decision-tree runner) is later implemented, its test spec can load
this runbook as a fixture — that is a follow-on concern, not this spec's.

---

## 8. Documentation updates

- `/home/user/k8-platform/docs/operations.md` — add a "Runbooks" section
  near the bottom with one bullet:
  "`docs/runbooks/runbook-apply-zero-resources.md` — Apply complete: 0 added
  silent no-op class (`triggers_replace` pattern, PR #67)."

- `/home/user/k8-platform/ai/handoff.md` Critical behavioral rules table
  (line 144) — append "See `docs/runbooks/runbook-apply-zero-resources.md`"
  to the "Zero changes after a manifest edit" row. One-phrase addendum.

- `/home/user/k8-platform/AGENTS.md` — no edit now. If retro-70 AGENTS-MD
  Suggestions 1 and 3 later land, the implementing agent should add a
  runbook pointer to each rule body.

- SPEC-B3 — no edit required; SPEC-B3 §7 handles its own handoff entry.

---

## 9. Workflow / auto-invocation wiring

This spec is purely manual documentation. The runbook is not auto-invoked
by any hook or CI workflow; it is read by an agent or operator when the
symptom (`Apply complete! Resources: 0 added`) is observed.

The unit test (`test_runbook_apply_zero_resources.sh`) wires into
`tests/unit/run.sh` (one appended line), which is called by the existing
`.github/workflows/terraform-test.yml` at `(phase=test, action=test-unit)`.
So while the runbook itself is manual, the test that asserts the runbook
exists and is non-trivially populated runs on every push to a non-main
branch — it prevents the runbook from being accidentally deleted or
accidentally emptied.

No new workflow file, no new job, no new GitHub Actions secrets.

---

## 10. Discoverability

1. **Mechanical enforcement** — `tests/unit/test_runbook_apply_zero_resources.sh`
   fails CI (unit-tests workflow) if the runbook file is deleted, if the
   `SPEC-B3` cross-reference is removed, or if the `triggers_replace` /
   `sha256` content is cleared. The failure message names the missing string
   and the expected file path, pointing the agent directly at what to restore.

2. **Documentation pointer** — `docs/operations.md` "Runbooks" section (added
   by this spec) is the canonical entry point for any agent reading the
   operations guide. The `ai/handoff.md` Critical behavioral rules table row
   (updated by this spec) is the entry point for any agent reading the handoff
   immediately after encountering a silent no-op. Both pointers land on the
   runbook file.

3. **Adversarial-review trigger** — AGENTS.md §6.4 adversarial review checklist
   should include: *"Does the test plan cover what happens when a
   `terraform_data` manifest edit produces 0 changes? Is the
   `runbook-apply-zero-resources.md` reference in the apply-step docs up to
   date?"* This surfaces the runbook as a check item whenever new
   `terraform_data` resources are being designed.

---

## 11. Verification checklist

The implementing agent runs these checks after creating all files:

- [ ] `test -f /home/user/k8-platform/docs/runbooks/runbook-apply-zero-resources.md`
  returns 0 (file exists).
- [ ] `wc -l /home/user/k8-platform/docs/runbooks/runbook-apply-zero-resources.md`
  returns a value between 80 and 300.
- [ ] `grep -q "SPEC-B3" /home/user/k8-platform/docs/runbooks/runbook-apply-zero-resources.md`
  returns 0.
- [ ] `grep -q "triggers_replace" /home/user/k8-platform/docs/runbooks/runbook-apply-zero-resources.md`
  returns 0.
- [ ] `grep -q "sha256" /home/user/k8-platform/docs/runbooks/runbook-apply-zero-resources.md`
  returns 0.
- [ ] `grep -q "26354235231" /home/user/k8-platform/docs/runbooks/runbook-apply-zero-resources.md`
  returns 0 (the CI run that produced the silent no-op is cited).
- [ ] `bash tests/unit/test_runbook_apply_zero_resources.sh` exits 0 with no
  FAIL lines.
- [ ] `bash tests/unit/run.sh` output includes `test_runbook_apply_zero_resources`
  in its banner and the final SUMMARY shows 0 failures.
- [ ] `grep -c "run_suite.*test_runbook_apply_zero_resources" tests/unit/run.sh`
  returns ≥ 1.
- [ ] `grep -q "runbook-apply-zero-resources" /home/user/k8-platform/docs/operations.md`
  returns 0 (pointer added to operations guide).
- [ ] `grep -q "runbook-apply-zero-resources" /home/user/k8-platform/ai/handoff.md`
  returns 0 (pointer added to handoff critical rules table).

---

## 12. Rollout notes

- **Backward-compatible.** New file under `docs/runbooks/` plus a new unit
  test; the three modified files (operations.md, handoff.md, run.sh) receive
  additive edits only. Nothing existing is removed or changed semantically.

- **Audit before merge.** Confirm `docs/runbooks/` does not already contain
  conflicting content from a prior agent.

- **SPEC-B3 ordering.** Independent. The runbook references SPEC-B3's lint
  path; if SPEC-B3 has not landed yet, the reference is forward-looking
  (acceptable for documentation). If SPEC-B3 lands first, the runbook can
  cite the actual script path instead of "see SPEC-B3".

- **Pluralsight sandbox constraints.** Irrelevant — no AWS calls, no cluster
  mutations, no EC2 provisioning.

- **Branch sequencing.** Standalone. No clustering dependency; can land
  before or after any other spec in the current queue.

---

## 13. Estimated effort

**S** (≤1 hour).

Breakdown:
- **Authoring the runbook** (~20 min): the content is already fully specified
  in §5.1 above and in the retrospective source material. The implementing
  agent assembles it from those fragments. No design decisions remain open.
- **Writing the unit test** (~10 min): four grep assertions + test-helpers.sh
  wiring, ~30 lines of bash. No brace-depth parsing, no fixture corpus
  required.
- **Editing three existing files** (~5 min): one line in `run.sh`, one
  sentence in `docs/operations.md`, one row update in `ai/handoff.md`.
- **Running the §11 verification checklist** (~5 min): all eleven checks are
  one-liners with no network or cluster dependency.

Total: approximately 40 minutes wall-clock for a focused implementing agent.
No rollout audit cost (no existing code affected). No review-cycle risk (no
behavioral change, no linting rule, no resource provisioning). Effort
category S is firm.
