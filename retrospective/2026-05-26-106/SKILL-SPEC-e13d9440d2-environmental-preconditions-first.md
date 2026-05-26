# Spec: `environmental-preconditions-first`

- **ID**: SKILL-SPEC-e13d9440d2
- **Source retrospective**: ../2026-05-26-106.md

## Intent

When CI fails for a managed-resource or infrastructure scenario, verify environmental preconditions (AWS account identity via `sts get-caller-identity`, GitHub Actions secrets currency, state bucket existence) BEFORE forming a code-hypothesis. Account rotation per AGENTS.md §8.1 invalidates handoff state and makes code-debugging on top of stale creds counterproductive.

## Trigger

**Direct**: "is the AWS account current?", "did the account get rotated?", "check the preconditions"

**Proactive**: Session start (always). AND any time a CI failure shows infrastructure-level errors:
- `Unable to find remote state`
- `InvalidClientTokenId` / `The security token included in the request is invalid` / `403 Forbidden`
- `connection refused` / `dial tcp: lookup … no such host` from kubectl
- Real-AWS chainsaw scenarios timing out at 245s with `Ready=False, message: "Unready resources: ..."` (the original `00-situation.md` symptom)
- `AccessDenied` on any AWS API call

**Negative**: Skip for pure unit-test failures, kubeconform failures (those are code-shaped). Skip for terraform plan failures that show specific .tf syntax errors (those are code-shaped).

## Inputs

- Current AWS credentials (whatever's in the shell environment)
- The repo's `ai/handoff.md` Environment State block (read but DO NOT trust it as ground truth)
- The current GitHub Actions repo (for cross-referencing secrets)

## Outputs

- A pass/fail verdict on each precondition with evidence
- If any fail: a clear "STOP" signal with the specific remediation step
- If all pass: greenlight to proceed with code-hypothesis debugging

## Workflow

1. **Verify AWS account identity**:
   ```bash
   aws sts get-caller-identity 2>&1
   ```
   If this fails with `InvalidClientTokenId` or `ExpiredToken`: AWS creds are stale. STOP. Tell user to rotate.

2. **Verify state bucket exists** (if Terraform is in scope):
   ```bash
   ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
   aws s3 ls "s3://k8-platform-tfstate-${ACCOUNT_ID}/" 2>&1 | head -3
   ```
   If `NoSuchBucket`: phase 0 base hasn't been applied on this account. STOP. Tell user to dispatch `terraform-test phase=base apply-and-verify` first.

3. **Verify cluster reachability** (if kubectl is in scope):
   ```bash
   kubectl version --short --request-timeout=5s 2>&1
   ```
   If `connection refused` / `dial tcp lookup failed`: kubeconfig is stale or cluster torn down. STOP.

4. **Compare against the handoff doc**:
   ```bash
   grep -E "AWS account|Phase 0|Phase 1" ai/handoff.md
   ```
   If the handoff lists a specific account ID different from `$ACCOUNT_ID`: the handoff is stale per AGENTS.md §8.1. Note for the run summary.

5. **For chainsaw scenarios specifically**: there's no way from the sandbox to verify the GitHub Actions secrets match the live account, so this becomes a question for the user — surface it in the morning summary.

6. Emit a `PRECONDITIONS_OK=yes/no` verdict and a remediation list.

## Concrete examples

### Example 1 — the 2026-05-26 fast-fail (handoff stale)

Session started with handoff saying "Phase 0 applied". Lead-agent dispatched `terraform-test phase=management apply-and-verify` based on that line. Run 26436447517 failed in 68 seconds with `Error: Unable to find remote state`. **The skill would have caught this before dispatch**: `aws s3 ls s3://k8-platform-tfstate-${ACCOUNT_ID}/` would have returned NoSuchBucket, revealing the rotated account. Cost of NOT having the skill: one fast-fail run + ~5 min of lead-agent log inspection.

### Example 2 — the 245s timeout (skill matches §10.1)

Chainsaw run 26440276628 had 3 platform-secret scenarios fail with `Ready=False, message: "Unready resources: asm-secret"` after exactly 245s — identical to the original `00-situation.md` symptom. The skill matches: testing-guidelines §10.1 explicitly says this pattern + a rotated test account means GitHub Actions secrets are likely stale. The skill's emit: `PRECONDITIONS_OK=no; rotate Actions secrets to current account; do NOT debug code`.

## Anti-patterns

- **Trusting `ai/handoff.md`'s state assertions as ground truth.** The handoff is the previous session's belief, not a runtime check. AGENTS.md §8.1 calls this out.
- **Skipping the skill because "I just verified yesterday"**. Account rotation can happen between any two sessions. The check is cheap (one `aws sts` call).
- **Conflating Terraform state errors with code errors**. `Unable to find remote state` is environmental, not a tf code bug.
- **Debugging code on top of a stale-creds failure**. If chainsaw scenarios time out at 245s with the original-symptom shape, the v2.5.0 migration didn't regress; the AWS creds are stale.

## Acceptance criteria

1. The skill runs in under 30 seconds (3 AWS API calls + a grep).
2. It produces a structured verdict (`PRECONDITIONS_OK=yes/no` plus per-check status).
3. On a rotated account, it identifies the rotation before any subsequent code-hypothesis work.
4. It does NOT mutate any state (read-only AWS + kubectl + grep).
5. It can be invoked as `bash scripts/whereami.sh --json` followed by the additional checks — i.e., it composes with the existing SPEC-S4 tool.

## Files this skill creates / modifies

- No files created. May echo a tabular precondition-status table to stdout.
- Optional: write `/tmp/preconditions.json` for subagent consumption.
