# Scope envelope — autonomous run 2026-05-26 (Crossplane v1→v2 migration EXECUTION)

**Run start:** 2026-05-26
**Driving prompt:** execute the migration plan synthesized in
`ai/crossplane-v1-v2-un-fuckify/40-final-plan.md` (PR #99, merged).
**Skill:** `autonomous-run`.
**Authorization to act:** user is structurally absent for the
duration of this overnight/long-running execution. Per the task
prompt: "treat this as an overnight/long-running task — load the
autonomous-run skill". Approval comes from chat after the morning
review of the run-summary PR; no per-PR pause.

**Branch policy.** Each chunk lives on its own branch stacked off the
previous tip per AGENTS.md §3. The orchestrator branch
`claude/crossplane-v1-v2-migration-exec-88kDe` holds the envelope
itself; each subsequent PR's head branch is named
`claude/v2-exec-<segment-or-step>-NN`.

---

## 1. Current state of the world (verified at run start)

| Item | State | Source |
|---|---|---|
| PR #97 (kubeconform path filter) | **MERGED** | commit `023f0a2` |
| PR #98 (provider v1.12.0 → v2.x bump) | **MERGED** (as v2.5.4 originally) | commit (via merge) |
| PR #100 (v2.5.4 → v2.5.0 follow-up fix) | **MERGED** | commit `f37f8e3` / `266bb12` |
| PR #99 (migration planning docs) | **MERGED** | commit `0bf5b1b` |
| PR #91 (SPEC-A4 chainsaw catch hook) | **OPEN** | base=main, head=`claude/auto-run-2026-05-25-phase-2-A4` @ `380fbfe` — v1-flavored, needs rebase + residue fixes |
| PR #94 (SPEC-C4 chainsaw goldens) | **CLOSED, NOT MERGED** | matches plan disposition (selective salvage owed) |
| `variables.tf` provider pin | `v2.5.0` ✅ | verified |
| `tests/chainsaw/versions.env` pin | `v2.5.0` ✅ | verified |
| `_smoke` workflow guard | **NOT YET ADDED** | plan called for adding this to #98 — was skipped; chainsaw is `workflow_dispatch`-only per §6.7 so this is hygiene-only, not blocking |
| SEG-3 unit-test skip patch (planned to stack on #98) | **NOT NEEDED YET** | unit tests still assert v1 strings vs still-v1 manifests; they go red only at SEG-1 cutover. The skip will be moot once Wave 2 brings re-enabled v2 assertions in the same PR |

**Bottom line.** Pre-flight (§4 steps 1–4) is effectively done. The
plan's "amend #98 to v2.5.0 + add _smoke guard + SEG-3 skip patch +
merge stack" got compressed into separate merges (#98 → #100). The
`_smoke` guard and SEG-3 skip patch were deemed unnecessary by the
previous session's merge actor because: (a) chainsaw is dispatch-only,
not push-triggered; (b) unit tests still pass against unchanged v1
manifests. I will NOT relitigate that compression; I pick up from §4
step 4 (parallel SEG-2 / SEG-4 PR-T1).

---

## 2. What I plan to do

In approximate execution order; each is one PR unless flagged:

1. **PR-A: SEG-4 PR-T1 — tooling regen.** Pre-flight `curl -I` URL
   matrix (Step 0); bump `scripts/fetch-crds-for-kubeconform.sh` to
   v2.5.0 (drop legacy `*.aws.upbound.io_` URLs, add `*.aws.m.upbound.io_`);
   regenerate `kubeconform-schemas/` (delete + repopulate ~9 dirs);
   fix `scripts/crossplane-trace.sh` L215 case-branch (`.m.upbound.io`
   glob); update `scripts/diag-component.sh` (CRD probe + jsonpath +
   group strings); edit 6 trace JSON fixtures (apiVersion); audit 2
   claim JSON fixtures; update 5 kubeconform YAML fixtures (add
   `kind: ClusterProviderConfig`); update 1 composition-render fixture.
   **No SEG-1 dependency** — derived from upstream URLs.
2. **PR-B: SEG-2 — Terraform / IRSA.** `helm.tf` Function apiVersion
   `pkg.crossplane.io/v1beta1` → `v1` + unconditional pre-delete line;
   add `kubectl rollout status` + SA post-check assertion after
   delete-deploy; bump Provider package URL to `v2.5.0`; audit Helm
   chart `--set args[]` against v2.3 chart values; ArgoCD bootstrap
   gate (Option A: PR description instructs operator to pause
   ArgoCD app before apply, restore after Wave 2 merges); bump
   `terraform.tfvars.example` stale values. **Parallel with PR-A.**
3. **Verification gate (NOT a PR):** dispatch
   `terraform-test.yml` (phase=management, action=apply-and-verify)
   against post-PR-B SHA. The `[management] e2e-verify` step is the
   IRSA probe surrogate (kind has no OIDC; only real EKS exercises
   IRSA round-trip). Watch with `terraform-ci-watch`. **HARD GATE
   before Wave 2.** If red: fetch logs first (testing-guidelines §10).
4. **PR-C: Wave 2 cutover — SEG-1 manifests + SEG-3 tests + #91
   residue.** Single stacked PR (or 3 stacked siblings if the diff
   becomes unwieldy) covering:
   - SEG-1: 2 XRDs to `apiextensions.crossplane.io/v2` + scope:
     Namespaced + no `claimNames`; 2 Compositions with `.m.upbound.io`
     groups, `managementPolicies: [Observe, Create, Update, Delete]`,
     `kind: ClusterProviderConfig`; 2 example claim files rewritten
     as XRs; 2 render-fixture `input.yaml` rewritten; ArgoCD glob
     tighten + sync-wave annotations; live XR conversion; delete
     Kyverno policy 09.
   - SEG-3: chainsaw `run.sh` heredoc `ClusterProviderConfig`; 3
     `platform-secret/*` scenarios drop `spec.resourceRef.name` walk;
     integration tests 05/06/11 group rename + 06 inline XRD
     `claimNames` removal + `scope: Namespaced`; 4 unit tests
     re-enabled with v2 assertions; new positive `scope: Namespaced`
     and `kind: ClusterProviderConfig` assertions.
   - #91 rebase onto post-PR-B main + 6-file catch-block v1 residue
     fixes (`catch-block.yaml` `for claim_kind` loop + `kubectl get
     composite`; 5 scenario paste sites).
   - **Pre-merge gate (AGENTS.md §6.7):** dispatch `chainsaw.yml`
     against PR-C HEAD SHA with `scenario_filter=_smoke` first to
     iterate quickly; final dispatch must be full scenario set green.
5. **PR-D: SEG-4 PR-T2 — render-fixture goldens.** Generate
   `expected.yaml` for both XRDs via
   `scripts/composition-render.sh --all`; commit.
6. **PR-E: SEG-4 PR-T3 — chainsaw goldens + #94 selective salvage.**
   On a fresh branch `claude/seg-4-c4-reauthor`: cherry-pick from
   closed PR #94 the 5 enforcer unit tests + Bug 4 fixture (6 files);
   in-place deterministic edits to 3 `external-secret.yaml` goldens
   (rename API group + `providerConfigRef.kind`); regenerate 3
   `asm-secret.yaml` goldens from live chainsaw output; fix
   `_meta/composition-drift` kubectl-group string.
7. **Final PR-F: run-summary + retrospective.** `run-summary-2026-05-26.md`
   at repo root + `retrospective/2026-05-26-PPP.md` per
   `self-retrospective` skill; update `ai/handoff.md` to reflect
   migration outcome.

**Total estimated PRs: 6-10** (PRs A-F plus 0-3 decision briefs and
0-2 CI-fix mini-PRs).

---

## 3. What I plan to NOT do

- **NOT touch `ai/crossplane-v1-v2-un-fuckify/*.md`.** Plan docs are
  frozen for traceability. If reality diverges, note in PR body +
  retro, never edit the plan.
- **NOT begin Phase 3+ work.** Migration completion is the scope; phase
  3 ApplicationSet plumbing (referenced in SEG-1 §3 Q-7) is a follow-up.
- **NOT relitigate pre-committed cross-segment decisions** (provider
  v2.5.0, `kind: ClusterProviderConfig`, `apiextensions.crossplane.io/v2`,
  `managementPolicies: [Observe, Create, Update, Delete]`, DROP legacy
  CRD URLs). 24 subagents + 10 reviews thought hard about these.
- **NOT pre-empt user merge authority** for any PR. Each PR opens
  ready-for-review (not draft); user merges in the morning.
- **NOT destroy live AWS resources** beyond what SEG-1 Step 3 drain
  authorizes (drain of `platform.k8-platform.io` and `aws.upbound.io/*`
  managed-resources only). If a live PlatformCluster carries real
  workloads (Q-1 of plan), write a decision brief before draining.
- **NOT skip the testing-guidelines §10 rule** (fetch the failure log
  via ext-github BEFORE forming hypotheses on any CI failure).

---

## 4. Scale estimate

- **Target PR count:** 6-10 PRs (plus the morning-summary PR).
  Quality over count per the user's prompt.
- **Subagent count estimate:** ~10-20 (per-segment implementer
  subagents in worktree isolation; pre-test adversarial reviewers;
  CI-fix subagents).
- **Expected wall-clock:** unbounded by user; bounded by stop
  conditions in §6. Plan estimates ~15.5 engineer-hours; aggressive
  ~3-4 days; conservative ~1 week.

---

## 5. First decision points

These are predicted at envelope time; each will get a decision brief
+ 2 adversarial rounds at the moment it materializes:

1. **D-Q4 — Helm chart `--set args[]` audit.** Plan SEG-2 step 5a
   says audit `--enable-realtime-compositions=false`,
   `--enable-ssa-claims=false`,
   `--enable-custom-to-managed-resource-conversion=false` against
   v2.3 chart values. If any flag is deprecated or renamed:
   **Lead-agent current best:** remove deprecated flags from helm.tf
   in PR-B and document the removed flags in PR description.
   **Alternative:** keep flags + accept warnings.
   **Rewind:** PR-B revert.
   *Brief required only if a flag is structurally broken.*
2. **D-Cutover-shape — Wave 2 single PR vs 3-stacked.** Plan §4 step 8
   says "single stack of stacked PRs". §5 says "Wave 2 MUST merge as a
   single stack". Practical question: do I produce 1 large PR or 3
   stacked sibling PRs?
   **Lead-agent current best:** 3 stacked PRs (SEG-1, SEG-3, #91-rebase)
   for review granularity; merge them in a single window. Atomicity is
   preserved by merging them together.
   **Alternative:** 1 single PR.
   **Rewind:** revert merge commits in reverse order.
3. **D-Q1 — Drain vs import of live PlatformCluster.** Default in plan
   is DRAIN. Only relevant if a live `PlatformCluster` carries real
   workloads at execution time.
   **Lead-agent current best:** drain (no real workloads expected on
   this ephemeral test account; check via `kubectl get xplatformclusters
   -A` before drain).
   **Alternative:** Observe-only import path (substantial extra work).
   **Rewind:** if import was needed but drain happened, the AWS
   resources will be recreated by the v2 XR. Some data loss possible
   for the secrets payload; cluster identity (EKS) is recreated fresh.
   *Brief required if any live XR carries real workloads.*

I do NOT plan to write briefs for the other plan-flagged questions
(Q-2 wait-for-claim ownership = SEG-3 owns; Q-3 Function pre-delete =
unconditional, zero-cost; Q-5 CRD URL stability = pre-flight gate
catches it).

---

## 6. What I'll surface in the morning summary

- The 6-10 PR URLs with suggested merge order respecting the
  hard gates (PR-B merged + IRSA verify green BEFORE Wave 2 stack
  merges; Wave 2 stack merges together in single window; PR-D/E
  only after Wave 2).
- Every decision brief written, with Round-1/Round-2 reviewer
  consensus and chosen option per brief.
- §11 Definition-of-Done checklist status (10 items) — which
  passed, which deferred with reason.
- The most consequential moment: **chainsaw.yml dispatched green
  against the post-Wave-2 SHA, full scenario set** (this is the
  hinge — "when that one passes, the migration succeeded" per user
  prompt).
- Any AWS-account-state drift surfaced during the run (account
  rotation per AGENTS.md §8.1).
- Open follow-ups (Phase 3 kubeconfig path change, RBAC namespace
  scoping replacement for deleted Kyverno policy 09).

---

## 7. Stop conditions

**Allowed to stop:**

- All §11 DoD items (10) green + run-summary + retro committed and
  pushed.
- Context budget approaches ~70% — write summary + retro NOW.
- Hard failure: AWS account access lost; GitHub MCP auth dropped
  after `github-connection-resilience` recovery attempts fail; kind
  cluster won't boot 3 times in a row; sandbox dies.
- 30-PR cap (very unlikely; plan estimates ~10 PRs total).
- User chat message arrives (interrupts unattended mode).

**NOT allowed to stop:**

- "I think I'm done" without verifying §11 DoD.
- A sub-phase closed — start the next.
- Stale-AWS-creds symptom returns — re-fetch logs and CONFIRM the
  diagnosis with current evidence per testing-guidelines §10.1; do
  NOT assume the previous session's diagnosis.
- Subagent returns ambiguous results — dispatch a clarifying brief.
- "Decision feels like user-judgment territory" — write a brief
  with 2 rounds × ≥3 reviewers, decide, document rewind.

---

## 8. End-of-run protocol (non-optional per skill)

1. Drain in-flight subagents / CI runs.
2. Commit + push everything; verify `git status` clean.
3. Write `run-summary-2026-05-26.md` at repo root.
4. Update `ai/handoff.md` if a phase closed.
5. Auto-invoke `self-retrospective` skill.
6. Subscribe to all PRs opened (PR-activity events into the next
   session via `mcp__github__subscribe_pr_activity`).
7. End with one-paragraph status message naming the run-summary PR,
   suggested merge order, and morning-review items.
