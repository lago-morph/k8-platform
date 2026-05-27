You are picking up the Crossplane v1 → v2 migration on the k8-platform
repo at /home/user/k8-platform. The bulk of the migration has merged
to main; what remains is **live-AWS verification on a freshly rotated
test account**, merging the open hotfix PR #105, and closing the stale
PR #91. Treat this as an overnight/long-running task — load the
`autonomous-run` skill.

## Read first (in this order, none optional)

1. AGENTS.md (entire file). Pay special attention to:
   - §3 (branch policy, stacked PRs)
   - §6.7 (manual-verify-then-PR for heavy CI)
   - §6.8 (Live-admission verification for v2 Crossplane CRD changes — **THIS IS NEW; required behavior for v2 manifest PRs**)
   - §6.9 (Read the failure log first — **THIS IS NEW; promotion of testing-guidelines §10**)
   - §8.1 (AWS account is ephemeral; whereami.sh as session-start gate)
   - §8.2 (Re-check environmental preconditions when CI surfaces infra-level errors — **THIS IS NEW; specific failure shapes that trigger env re-check**)
2. ai/testing-guidelines.md §10 and §10.1 (read-the-log-first; environmental-preconditions-before-code)
3. ai/crossplane-v1-v2-un-fuckify/40-final-plan.md (the master migration plan; you are executing §11 DoD items 5, 6, 8)
4. retrospective/2026-05-26-106.md (previous session's retrospective — phase-by-phase narrative of what's already shipped, including the 245s asm-secret timeout that motivated the AWS-creds rotation you've just performed)
5. retrospective/2026-05-26-100.md (other session's retrospective — adds context on the v1/v2 root-cause diagnosis and migration planning pipeline)
6. run-summary-2026-05-26.md (concise top-level summary of the previous run; "Morning-review items" and "What's next" sections name the exact follow-ups you're doing)
7. docs/decisions/0001-kubeconform-not-sole-gate-for-v2-crd-changes.md (the load-bearing ADR; defines why chainsaw must be live-dispatched for v2 PRs)

## State of the world at handoff

**AWS account**: freshly rotated. The user has updated repo Settings → Secrets → Actions with new `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_REGION`. **DO NOT trust this on faith** — verify with `aws sts get-caller-identity` in the first command, AND dispatch one workflow run to confirm CI uses the new creds.

**ai/handoff.md**: Phase 0 + Phase 1 lines say "applied" but reflect the OLD account. Treat as stale per AGENTS.md §8.1 until you re-verify on the rotated account and update the file.

**Merged to main (all retro work, all migration code except hotfix)**:
- PR #97, #98, #99, #100 — pre-flight: provider v1.12 → v2.5.0 + planning docs
- PR #101 — scope envelope `auto-002`
- PR #102 — SEG-2 terraform/IRSA helm.tf assertions (Function v1 pre-delete, rollout-status wait, SA-name post-check)
- PR #103 — SEG-4 PR-T1 tooling regen (kubeconform schemas v2.5.0, fixture v2-ification)
- PR #104 — Wave 2 cutover (SEG-1 manifests + SEG-3 tests + #91 catch hook cherry-pick)
- PR #106, #107, #108 — retrospectives + adoption of `AGENTS.md §6.8 §6.9 §8.2` + `docs/decisions/0001-…`

**Open PRs**:
- **PR #105** (`claude/v2-exec-hotfix-xrd-connsec` @ `6a47acf`) — Wave 2 hotfix. Removes v2-rejected `connectionSecretKeys`/`writeConnectionSecretToRef` from XRD + 3 sites; rewrites 8 v1 claim kinds in chainsaw scenarios to v2 XR kinds; drops v1-only `Offered` condition wait from `xrd-establishes`. **Last chainsaw dispatch (26440276628) got past XRD apply** (`xrd-establishes` PASS in 9s; `smoke-harness-works` PASS) but 3 real-AWS scenarios timed out at 245s with `Unready resources: asm-secret`. Diagnosed (NOT verified) as the AWS-creds-rotation symptom. **YOU verify whether rotation alone fixes it; if not, fetch the chainsaw log and diagnose further.**
- **PR #91** (`claude/auto-run-2026-05-25-phase-2-A4` @ `380fbfe`) — SPEC-A4 chainsaw catch hook. **Its content was cherry-picked into PR #104, which is merged.** Branch is stale — close without merging once you confirm the 8 file additions (catch-block.yaml + meta-test + 5 scenario pastes + enforcer test) are in main.

## Pre-committed cross-segment decisions — DO NOT relitigate

| Decision | Value |
|---|---|
| Provider tag | v2.5.0 |
| providerConfigRef.kind | ClusterProviderConfig |
| XRD apiVersion | apiextensions.crossplane.io/v2 |
| deletionPolicy replacement | managementPolicies: [Observe, Create, Update, Delete] |
| XR-level connection secrets | REMOVED in v2 (admission rejects); consumers read from MR's own connection-secret (Phase 3 follow-up) |

## Execution order

Run these steps in order. Each step has a gate; do not advance until the gate is green AND you have read the log to confirm (per §6.9, §10).

### Step 1 — Environmental precondition check (per AGENTS.md §8.2)

Before any workflow dispatch:

```bash
scripts/whereami.sh --json
aws sts get-caller-identity
aws s3 ls s3://k8-platform-tfstate-$(aws sts get-caller-identity --query Account --output text)/ 2>&1 | head -3
```

If `whereami.sh` or `aws sts` fail: STOP. The rotation didn't take. Tell the user.

If the state bucket doesn't exist on the rotated account: that's expected (it gets created by `terraform-test phase=base` bootstrap step) — proceed to step 2.

If the state bucket EXISTS but contains state from a different (older) account: that's a problem — flag to user.

### Step 2 — terraform-test phase=base apply-and-verify against main

Dispatch via ext-github (`op_2acb005c9f3704ad`):
- workflow_id: terraform-test.yml
- ref: main
- inputs: {phase: base, action: apply-and-verify}

Watch with `terraform-ci-watch` skill. Expected wall-clock ~3 min.

**On failure**: fetch the job log per §6.9 (`op_c08d23e5bd6966cb`). Classify per
`.claude/skills/terraform-ci-watch/reference/failure-taxonomy.md`. Iterate (3-strike cap).

**Pass criterion**: workflow run conclusion=success; `[base] e2e-verify` step green.

### Step 3 — terraform-test phase=management apply-and-verify against main

Dispatch (same op, inputs `{phase: management, action: apply-and-verify}`). Expected wall-clock ~15 min.

**This is the load-bearing step.** It will:
- Install Crossplane v2.5.0 providers on the freshly-applied EKS cluster
- Exercise the helm.tf Function v1 pre-delete + rollout-status + SA-name post-check
- Run `[management] e2e-verify` (ArgoCD + ESO + Crossplane + ingress-nginx + external-dns + Kyverno)

**Important**: ArgoCD is going to sync the post-Wave-2 manifests against the now-v2 providers. If any manifest in main still triggers a v2-admission rejection that PR #105's hotfix is supposed to fix (e.g., `connectionSecretKeys` on the platform-cluster XRD), ArgoCD app will report Degraded and `[management] e2e-verify` may fail. **That's expected** — it's why PR #105 needs to merge before chainsaw full can pass.

**On failure**: fetch log; if it's an ArgoCD-degraded-from-XRD-rejection issue, that's a known-state — proceed to step 4 (chainsaw against PR #105's branch will validate the hotfix; once #105 merges, ArgoCD will recover).

### Step 4 — chainsaw FULL against PR #105's branch SHA

Dispatch chainsaw.yml:
- workflow_id: chainsaw.yml
- ref: claude/v2-exec-hotfix-xrd-connsec
- inputs: {commit_sha: 6a47acfe3cfb85d7507b3fd01a29113b2dadc5e1, scenario_filter: ""}

**Per AGENTS.md §6.8**: this is the live-admission verification gate before merging PR #105. Expected wall-clock ~10 min for full set.

**Pass criterion**: all 4 real scenarios green: `xrd-establishes`, `claim-creates-secret`, `claim-deletion-cleanup`, `claim-rotation`. Plus `smoke-harness-works` and `meta-catch-fires`.

**On failure**: per §6.9 + §10, fetch the job log FIRST. Common shapes:
- `is invalid: spec: Invalid value: …` — v2 admission rejection (need a fix beyond PR #105)
- `Ready=False, message: "Unready resources: …"` for 245s — AWS auth issue. Re-verify creds per §8.2. If creds are correct, the catch block may not be dumping MR conditions (the 2026-05-26 run flagged a namespace-mismatch bug in the catch block: catch reads `$NAMESPACE` = chainsaw's per-scenario namespace, but scenarios apply XRs in `namespace: default`). Fix the scenarios to use `($namespace)` for XR namespace, then re-dispatch.
- `no matches for kind …` — v1 residue not caught by PR #105. Patch on the hotfix branch.

3-strike cap per failure mode. If you blow through 3 strikes on the same mode, STOP and write a decision brief per `autonomous-run` skill.

### Step 5 — Merge PR #105 (only after step 4 green)

Use `mcp__github__merge_pull_request`. Method: merge (not squash — preserve the two hotfix commits for audit).

### Step 6 — chainsaw FULL against post-#105 main (the §11 DoD item)

After PR #105 merges, GitHub gives you a new main SHA. Dispatch chainsaw.yml against main with `commit_sha=<new main SHA>`, `scenario_filter=""`.

**Pass criterion**: all 4 real scenarios green. This is the migration's done criterion per the user's previous prompt: "chainsaw.yml dispatched green against the post-Wave-2 SHA, full scenario set, including the 3 platform-secret scenarios that surfaced the original PendingExternalResource symptom. When that one passes, the migration succeeded."

### Step 7 — Close PR #91

Verify content is in main first:
```bash
ls tests/chainsaw/_lib/catch-block.yaml tests/unit/test_chainsaw_catch_block.sh
git log main --oneline -- tests/chainsaw/_lib/catch-block.yaml | head -3
```

If both files exist and the catch-block.yaml commits are in main: close PR #91 via `mcp__github__update_pull_request` with `state=closed`. Add a closing comment via `mcp__github__add_issue_comment`: "Content merged via PR #104 (Wave 2 cutover, commit 5044815 + follow-ups). Closing without merge — branch is stale."

### Step 8 — Open SEG-4 PR-T2 (render-fixture goldens)

Per the migration plan SEG-4 §2.4 PR-T2:
- Branch: `claude/v2-exec-seg4-pr-t2-render-goldens` (off main)
- Run `bash scripts/composition-render.sh --all` to generate `expected.yaml` goldens for both XRDs against the v2 Compositions in main
- Commit both `expected.yaml` files
- Open PR ready-for-review

`crossplane` CLI may not be in your sandbox. If so: the unit-tests workflow installs it during CI (per `.github/workflows/unit-tests.yml` "Install crossplane CLI" step), so generate the goldens via a CI-side mechanism, OR install crossplane locally and run. If neither works, document the blocker in the PR description and defer PR-T2.

### Step 9 — Open SEG-4 PR-T3 (chainsaw asm-secret goldens + PR #94 selective salvage)

Per the migration plan SEG-4 §2.4 PR-T3 and SEG-5 §5.4:
- Branch: `claude/seg-4-c4-reauthor` (off main)
- Cherry-pick from closed PR #94's branch (`claude/auto-run-2026-05-25-phase-2-C4` @ `5f43f46`):
  - 5 enforcer unit tests
  - 1 Bug 4 fixture (`tests/fixtures/compositions/platform-secret-pre-pr61.yaml`)
- In-place edit the 3 deterministic external-secret goldens (rename API group + add `kind: ClusterProviderConfig`)
- Run live chainsaw against post-#105 main to capture the 3 asm-secret goldens (volatile AWS-shape fields require live regen)
- Fix `tests/chainsaw/_meta/composition-drift/chainsaw-test.yaml` kubectl-group string
- Commit, open PR

### Step 10 — Update ai/handoff.md

Phase 0 + Phase 1 lines updated to reflect the rotated account (use the run URLs from steps 2 and 3 as evidence). Use `chore(handoff): post-rotation verification 2026-05-DD` commit message.

### Step 11 — End-of-run protocol

Per `autonomous-run` skill:
1. Drain any in-flight subagents/CI
2. Verify `git status` clean
3. Write `run-summary-YYYY-MM-DD.md` (note: NOT 2026-05-26, since the previous one already exists; use today's date verified via `date -u`)
4. Auto-invoke `self-retrospective` skill
5. Subscribe to all PRs opened
6. End with one-paragraph status message naming the summary PR + remaining morning-review items

## Capabilities to use

- **`autonomous-run`** skill — load at session start; the procedural backbone of an unattended run
- **`terraform-ci-watch`** skill — drives every terraform-test dispatch + watch + 3-strike escalation envelope
- **`ext-github`** skill — sandbox's only path to GitHub Actions API:
  - `op_2acb005c9f3704ad` — workflow_dispatch (terraform-test, chainsaw)
  - `op_e5f9dfd148ed5018` — list workflow runs (and substitute for missing GET-single-run)
  - `op_2064ead94c9950bc` — list jobs in a run
  - `op_c08d23e5bd6966cb` — download per-job logs (the load-bearing op for §6.9)
- **GitHub MCP** (`mcp__github__*`) — PR operations: read, comment, merge, close, list. Use these for everything PR-shaped that's not Actions API.
- **`crossplane-claim-verify`** skill — invoke after step 3 (management apply) to verify Crossplane core is Synced/Ready
- **`parallel-subagent-fanout`** skill — if you need parallel work; not expected for this run since the steps are mostly serial
- **`github-connection-resilience`** skill — if GitHub MCP auth drops mid-run; uses checkpoint+resume pattern
- **`self-retrospective`** skill — end of run only

## Discipline (mandatory)

- **AGENTS.md §6.9 / testing-guidelines §10**: fetch the failure log via ext-github BEFORE forming any hypothesis on a CI failure. The previous session's retrospective documents the cost of skipping this — multiple turns of wasted speculation.
- **AGENTS.md §6.8**: dispatch live chainsaw before relying on kubeconform alone for v2 CRD changes. Schema-pass is necessary but not sufficient.
- **AGENTS.md §8.2**: re-check environmental preconditions when CI shows infrastructure-level errors (`Unable to find remote state`, `InvalidClientTokenId`, 245s `Unready resources:` timeouts). DO NOT debug code on top of stale environment.
- **AGENTS.md §3**: never commit to main directly. Use named branches; stack PRs when work depends on unmerged work.
- **AGENTS.md §8.1**: ephemeral AWS account; never hardcode account IDs in any artifact (use `aws sts get-caller-identity` to derive at runtime).
- **3-strike cap**: per `terraform-ci-watch` §5, after 3 consecutive failed fix attempts on the same failure, STOP and emit the structured escalation report. Do not push a 4th attempt.

## When to write a decision brief

Per `autonomous-run` skill, write `decisions/auto-003-<slug>.md` (next sequence number after auto-002 which is the previous session's envelope) and dispatch ≥3 adversarial reviewer subagents (2 rounds) when you hit genuine user-input territory. Candidates this run:

- Step 4 chainsaw fails after rotation — possibly the catch-block namespace bug surfaces a deeper v2 issue
- Step 6 (post-#105 chainsaw) fails — could indicate the migration's underlying observe-roundtrip on v2.5.0 still has issues
- Hard CI failures after 3 auto-fix attempts on any step

Do NOT freeze and ask the user mid-run — they're absent by definition.

## Stop conditions (allowed)

- §11 DoD complete (10 items; check against `ai/crossplane-v1-v2-un-fuckify/40-final-plan.md` §11)
- Context budget ~70% (write summary + retro NOW)
- Hard failure: AWS account access lost (creds rotation didn't take); GitHub MCP auth dropped after recovery attempts fail
- 30-PR cap (very unlikely — this run probably opens 2-3 PRs total)

## NOT allowed stop conditions

- "I think the rotation is good" without `aws sts get-caller-identity` evidence
- A sub-phase closed — start the next one
- Stale-AWS-creds symptom returns (245s `Unready resources:`) — DO NOT assume rotation fixed it; re-fetch the log and confirm with current evidence
- Step 4 (chainsaw against #105 branch) green but step 6 not yet run — that's not done

## Scope envelope (write this BEFORE any non-Read tool call)

Before doing any work, write `decisions/auto-003-scope-envelope.md` per the `autonomous-run` skill template. This is the contract for the run. Aim for ~3-5 PRs (PR #105 merge happens via MCP, doesn't count as opening a new PR; PR-T2 + PR-T3 + handoff update + run-summary + retro = 4-5 PRs).

## Done criterion

§11 of `ai/crossplane-v1-v2-un-fuckify/40-final-plan.md` — 10 items. The remaining gaps from the previous run:

- §11 item 5: chainsaw full green against post-Wave-2 main (achieved in Step 6 above)
- §11 item 6: `bash tests/integration/run.sh` against live cluster (achievable once step 3 brings up the cluster)
- §11 item 8: Phase 1 + Phase 2 verified on a fresh AWS account (steps 2 + 3 + 6 satisfy this)
- §11 item 9: PR #94 closed with salvage complete; 6 goldens regenerated (steps 8 + 9)

When all 10 §11 items pass: the migration succeeded.

---

That's it. Now: write your scope envelope, then start executing.
Don't skip the §1 read list — the AGENTS.md §6.8 §6.9 §8.2 rules are
new and the testing-guidelines §10 + §10.1 are the load-bearing
discipline rules for this run. Trust the artifacts, verify
pre-conditions, follow the gate sequence.
