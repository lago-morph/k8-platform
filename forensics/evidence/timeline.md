# Project Timeline — Forensic Reconstruction

**Corpus:** 723 commits, 2026-05-02 through 2026-06-10, single unbroken main branch.
**Commands used:** `git log`, `git diff-tree`, `git show`, `git shortlog`, `git rev-list`.

---

## Headline Facts (10 bullets)

1. [FACT] Repository spans **40 days** (2026-05-02–2026-06-10), 723 commits, 214 merged PRs; initial "Add files via upload" commit `bd420a99` on 2026-05-02. [cmd: `git rev-list --count HEAD`; `git log --oneline --reverse | head -2`]
2. [FACT] **12 named autonomous runs** exist in commit history: three date-labeled (2026-05-25, 2026-05-26, 2026-05-28 = v1→v2 migration tail), then auto-003 through auto-016. No auto-001 or auto-002 label appears anywhere in commit messages. [cmd: `git log --format="%s" | grep "auto-0"`]
3. [FACT] The **Crossplane v1→v2 migration** was planned in `ai/crossplane-v1-v2-un-fuckify/` (situation doc `a7c6efdf`, 2026-05-26) and executed the same day via PRs #101–#104; a tail cleanup continued through 2026-05-27/28 (auto-003). [cmd: `git log -- ai/crossplane-v1-v2-un-fuckify/`]
4. [FACT] **No repo reset or fork occurred.** The git graph has a single root commit `bd420a99`. PR numbering did change merge-message format at PR #140 (2026-06-05): PRs 1–139 use `Merge pull request #N from lago-morph/<branch>`; PRs 140–214 use `Merge pull request #N: <title>`. Both formats retain two parents (merge commits, not squash). [cmd: `git log --format="%H %P" | grep "^9898fe9"` and `git log --oneline --reverse | head -2`]
5. [FACT] **Top-churned files** (by touch count across all commits): `ai/handoff.md` (70), `tests/unit/run.sh` (51), `AGENTS.md` (48), `terraform/management/helm.tf` (31), `docs/open-issues.md` (28). [cmd: `git log --format= --name-only | sort | uniq -c | sort -rn | head -10`]
6. [FACT] **Peak commit days**: 2026-05-23 (123 commits), 2026-06-07 (106), 2026-06-08 (73), 2026-05-25 (71), 2026-06-06 (65). The May 23 spike coincides with Phase 2 XRD scaffolding + chainsaw test harness introduction. [cmd: `git log --format="%ad" --date=short | sort | uniq -c | sort -rn`]
7. [FACT] **`SUBSTRATE-READINESS.md`** first appeared 2026-06-09 commit `fdad8e65`, introduced alongside AGENTS.md §6.41 as a clean-build evidence gate after an accountability retrospective (`fdf6a4e9`) documented repeated "done without clean-build testing" violations. [cmd: `git log -- SUBSTRATE-READINESS.md | head -3`]
8. [FACT] **Root-level run-summary file accretion**: earliest dated summary `run-summary-2026-05-25.md` (`6a0dd9fa`, 2026-05-25); then `run-summary-2026-05-26.md`, `run-summary-2026-05-28.md`; followed by `run-summary.md` (`947b7ae5`, 2026-06-05); then auto-009 through auto-016 summaries; plus `overnight-summary.md` (`330bd3b0`, 2026-05-29), `handoff-followups-2026-05-28.md` (`f95940032`, 2026-05-28). Currently 19 root-level `.md` files. [cmd: `git log --diff-filter=A -- "run-summary*"`]
9. [FACT] A **distress-signal commit** `i-am-a-fucking-idiot.md` (278 lines) was added via PR #116 (2026-05-27, commit `bdb7a418`) during the v1→v2 migration tail; it was sanitized into `handoff-recovery.md` via PR #117, and both stale files were deleted 2026-05-28 (`01d18589`). [cmd: `git show a5abe45e --stat`; `git show 01d18589 --stat`]
10. [FACT] **89 retrospective sessions** are logged under `retrospective/`, numbered by PR (e.g., `2026-05-17-13`, `2026-06-09-214`); AGENTS.md reached §6.41 (41 rules + sub-rules) by the final commit. [cmd: `ls retrospective/ | wc -l`]

---

## 1. Phase Structure — Distinct Eras

| Era | Date Range | Commits | Key Signal |
|---|---|---|---|
| Bootstrap | 2026-05-02–2026-05-03 | 14 | Initial scaffold: Iter 0 (VPC/Cognito) + Iter 1 (EKS/ArgoCD/Crossplane), CI, handoff doc |
| Slow build-up | 2026-05-04–2026-05-22 | ~31 | K8s version bump, skills import, AGENTS.md introduction, ext-github spec work |
| Intensive feature/test | 2026-05-23–2026-05-25 | 208 | Phase 2 XRDs (PlatformCluster, PlatformSecret), chainsaw harness, kubeconform hook, ~100 PRs |
| Crossplane v1→v2 migration | 2026-05-26–2026-05-28 | ~123 | Situation doc → 5-segment plan → execution (PRs #99–#116) → wave-2 hotfix → `auto-003` tail |
| Phase-2 verification | 2026-05-29–2026-06-04 | ~20 | `auto-004` phase-0/1/2 verified live; open-issues register started; account rotation noted |
| Phase 3–6 build (live) | 2026-06-05–2026-06-07 | ~219 | `auto-005`–`auto-013`; Phase 3 spoke, 4 obs, 5 Keycloak/DB, 6 workload1 scaffolding; ext-github; PR format change |
| Test-overhaul + hardening | 2026-06-07–2026-06-09 | ~101 | `auto-013`–`auto-016`; `tests/live/` suite, ADR-0006, SUBSTRATE-READINESS, IAM narrowing, accountability retro |

[FACT] Bootstrap commit `3c089664` (2026-05-03): `terraform/base/` + `terraform/management/` + `argocd/` + `crossplane/` skeleton all created simultaneously. [cmd: `git show 3c089664 --stat`]

[FACT] PR format change at PR #140 (2026-06-05): PRs 1–139 include `from lago-morph/<branch>` in merge subject; PRs 140–214 do not. Both still use two-parent merge commits. [INFERENCE] Likely a GitHub merge-method UI change or `gh pr merge` invocation style change; no structural repo change.

[OPEN] No explicitly labeled `auto-001` or `auto-002` runs exist. The first labeled autonomous run is the "Autonomous Phase 1+2 run" dated 2026-05-25 (unnamed), and `auto-003` is the first with an explicit tag. Whether `auto-001`/`002` were unnamed runs (2026-05-25/26 date-labeled summaries) or simply never labeled is unresolved.

---

## 2. Quantitative Shape

### Commits Per Day (calendar order)

| Date | Commits | Notable activity |
|---|---|---|
| 2026-05-02 | 2 | Initial upload + README |
| 2026-05-03 | 14 | Full scaffold |
| 2026-05-04–2026-05-21 | 18 total | Slow ramp (CI, skills, spec work) |
| 2026-05-22 | 14 | ext-github spec + retros |
| 2026-05-23 | **123** | Phase 2 scaffolding + chainsaw + ~50 PRs |
| 2026-05-24 | 26 | Chainsaw fixes |
| 2026-05-25 | 71 | Phase 1+2 autonomous run |
| 2026-05-26 | 52 | v1→v2 migration execution |
| 2026-05-27 | 24 | Migration tail + `i-am-a-fucking-idiot.md` |
| 2026-05-28 | 47 | Migration wiring + open-issues + AGENTS rule flood |
| 2026-05-29 | 15 | auto-004 verification |
| 2026-05-30–2026-06-03 | 3 total | Dead period (account rotation?) |
| 2026-06-04 | 2 | AWS account setup plan |
| 2026-06-05 | 48 | Phases 3–6 scaffolding + auto-005 live build |
| 2026-06-06 | 65 | Crossplane bootstrap deadlock fix; provider-k8s bump |
| 2026-06-07 | **106** | auto-012/013; test overhaul planning (9 PRs in one day) |
| 2026-06-08 | 73 | auto-014/015; live test suite; IAM tightening |
| 2026-06-09 | 19 | auto-016; SUBSTRATE-READINESS; accountability retro |
| 2026-06-10 | 2 | Forensics corpus + stray merge |

### Merge-PR Cadence

[FACT] 184 PRs merged out of #1–#214; 11 sequential gaps in PR numbers (PRs 2–18 not in git history — these are issues/PRs that were closed without merge or are GitHub issue numbers; also gaps at #22, #86, #89, #91, #94, #98, #105, #137, #149–152, #186). [cmd: `awk` analysis of `git log --format="%s" | grep "Merge pull request"`]

### Top-Churn Files

| Touches | File |
|---|---|
| 70 | `ai/handoff.md` |
| 51 | `tests/unit/run.sh` |
| 48 | `AGENTS.md` |
| 31 | `terraform/management/helm.tf` |
| 28 | `docs/open-issues.md` |
| 20 | `tests/chainsaw/run.sh` |
| 20 | `terraform/management/variables.tf` |
| 16 | `tests/chainsaw/platform-secret/00-claim-creates-secret/chainsaw-test.yaml` |
| 16 | `ai/testing-guidelines.md` |
| 15 | `tests/chainsaw/platform-secret/01-claim-deletion-cleanup/chainsaw-test.yaml` |
| 15 | `tests/chainsaw/platform-secret/02-data-rotation/chainsaw-test.yaml` |

[cmd: `git log --format= --name-only | sort | uniq -c | sort -rn | head -15`]

### Churn by Top-Level Directory

| Directory | File-touches |
|---|---|
| `tests/` | 534 |
| `retrospective/` | 364 |
| `ai/` | 254 |
| `.claude/` | 132 |
| `terraform/` | 128 |
| `kubeconform-schemas/` | 78 |
| `crossplane/` | 69 |
| `planning/` | 58 |
| `docs/` + `.github/` | 55 each |
| `scripts/` | 51 |

---

## 3. Major Component Introduction Dates

| Component | First commit | Date | Hash |
|---|---|---|---|
| `terraform/base/` (VPC, Route53, Cognito) | Bootstrap | 2026-05-03 | `3c089664` |
| `terraform/management/` (EKS, IRSA, ArgoCD, Crossplane, ESO) | Scaffold Iter 1 | 2026-05-03 | `3765c297` |
| `argocd/` (skeleton) | Bootstrap | 2026-05-03 | `3c089664` |
| `crossplane/` (XRDs skeleton) | Bootstrap | 2026-05-03 | `3c089664` |
| `AGENTS.md` | Introduced with TDD + full-test-bundle rules | 2026-05-23 | `8a5e13c3` |
| `tests/chainsaw/` harness | `feat(chainsaw): add Crossplane test harness` | 2026-05-23 | `422fda1d` |
| `.claude/skills/` | Slim CLAUDE.md + skills reorganize (#8) | 2026-05-03 | `f013df76` |
| `ai/crossplane-v1-v2-un-fuckify/` | Situation doc | 2026-05-26 | `a7c6efdf` |
| Crossplane v2 XRDs live (namespaced) | `feat(seg-1): migrate XRDs to apiextensions/v2` | 2026-05-26 | `6e671282` |
| `docs/open-issues.md` | Evidence-vs-hypothesis + open-issues register | 2026-05-28 | `392989f5` |
| `platform-services/` (skeleton) | Bootstrap Iter 0 | 2026-05-03 | `3c089664` |
| Phase 3 (spoke cluster) | Phase 3 — platform cluster + ACM Crossplane | 2026-06-05 | `9898fe93` |
| Phase 4 (observability) scaffold | `feat(phase4-observability)` | 2026-06-05 | `5edcf089` |
| Phase 5 (Keycloak/DB) scaffold | `feat(phase5-keycloak)` | 2026-06-05 | `7febe91a` |
| Phase 6 (workload1) scaffold | `feat(phase6-workload1)` | 2026-06-05 | `21f4278f` |
| `tests/live/` suite | `planning/test-overhaul` + live check scripts | 2026-06-07 | `dbb1ccf5` (plan) |
| `SUBSTRATE-READINESS.md` | Clean-build gate + AGENTS §6.41 | 2026-06-09 | `fdad8e65` |
| ADR-0001 (kubeconform not sole v2 gate) | Retrospective 2026-05-26-100 | 2026-05-26 | `60c26e1e` |
| ADR-0006 (test architecture) | `docs(decisions): adopt ADR-1946fbb159 as 0006` | 2026-06-07 | `eba68b21` |

---

## 4. Rework Signatures — Same Area Fixed Repeatedly

### 4.1 Crossplane Provider Bootstrap (helm.tf + crossplane-phase3.tf)

| Hash | Date | Message |
|---|---|---|
| `de6132ca` | 2026-05-25 | fix(crossplane): correct ClaimSSA flag name |
| `3e850a66` | 2026-05-25 | fix(crossplane): disable v2.3's newly-default beta features |
| `e635a1ed` | 2026-06-05 | fix(management): wait for provider package install before SA check |
| `2fe3f14e` | 2026-06-05 | fix(management): drop by-label provider delete/rollout |
| `99cc9745` | 2026-06-05 | fix(management): vendor crossplane chart — runner gets 403 from CDN |
| `a0bf9ea5` | 2026-06-06 | fix(mgmt): collapse duplicate family-aws Provider + order children |
| `e45bba99` | 2026-06-06 | fix(mgmt): self-heal wedged cluster — orphan-cleanup stray provider-family-aws |
| `f737e03a` | 2026-06-06 | fix(crossplane): child-provider IRSA via runtimeConfigRef (blocker #3) |

[FACT] `helm.tf` was touched 31 times; 8 consecutive fix commits spanning 2026-05-25 to 2026-06-06 address Crossplane provider bootstrap. The OI-2026-06-06-2 label ("provider-bootstrap deadlock") appears in two consecutive commits. [cmd: `git log -- terraform/management/helm.tf | grep fix`]

### 4.2 Chainsaw Platform-Secret Scenarios

| Hash | Date | Message |
|---|---|---|
| `907b8aaf` | 2026-05-26 | fix(seg-3+91): v2-ify catch-block.yaml + 6 scenario pastes |
| `6a47acfe` | 2026-05-26 | fix(seg-3): chainsaw scenarios use v2 XR kinds + Established-only |
| `d843915f` | 2026-05-27 | fix(seg-3): em-dash in tag-bound description rejected by AWS Tagging |
| `8298c1f8` | 2026-05-27 | fix(seg-3): chainsaw scenarios assert all 3 v2 XR conditions |
| `9103d9a0` | 2026-05-27 | fix(seg-3): chainsaw scripts use POSIX sh, drop bash-only pipefail |
| `41e661db` | 2026-05-27 | Wave 2 hotfix: 5 v2 admission/AWS-tagging/chainsaw fixes |
| `f5bf5465` | 2026-06-08 | Make chainsaw real-AWS asserts deterministic (OI-2026-05-28-1) |
| `89836cc8` | 2026-06-08 | Widen XR-Ready wait bound to 600s for slow ASM converge |

[FACT] The same chainsaw scenario file (`platform-secret/00-claim-creates-secret/chainsaw-test.yaml`) was touched 16 times. The recurrence OI-2026-05-28-1 (Issue A: real-AWS non-determinism) was first filed 2026-05-28 and finally closed 2026-06-08 — an 11-day open window. [cmd: `git log -- tests/chainsaw/platform-secret/00-claim-creates-secret/chainsaw-test.yaml`]

### 4.3 ArgoCD IRSA / ArgoCD Credentials

| Hash | Date | Message |
|---|---|---|
| `c7e50f6b` | 2026-06-07 | fix(argocd): annotate application-controller SA with IRSA role-arn |
| `434855e1` | 2026-06-06 | fix(crossplane): add shared ClusterProviderConfig/default (IRSA) via GitOps |
| (multiple) | 2026-06-05–07 | ArgoCD creds via tf-output (AGENTS §10.1), retro-driven |

[FACT] AGENTS §10.1 ("ArgoCD creds are a Terraform output") was added 2026-06-05 (`10.1-argocd-creds-terraform-output.md`); the ArgoCD IRSA annotation fix (`c7e50f6b`) came two days later. [cmd: `git log --diff-filter=A -- .claude/agents-md/10.1-argocd-creds-terraform-output.md`]

---

## 5. Root-Directory Accretion

| File | First commit | Date | Trigger |
|---|---|---|---|
| `run-summary-2026-05-25.md` | `6a0dd9fa` | 2026-05-25 | End of autonomous Phase 1+2 run |
| `run-summary-2026-05-26.md` | `891d008b` | 2026-05-26 | End of v1→v2 migration execution run |
| `handoff-followups-2026-05-28.md` | `f9594003` | 2026-05-28 | Session wrap-up helper list |
| `run-summary-2026-05-28.md` | `2e7f8c09` | 2026-05-28 | auto-003 migration tail summary |
| `overnight-summary.md` | `c7b4b5ab` | 2026-05-29 | auto-004 phase-2 verification result |
| `run-summary.md` (generic) | `947b7ae5` | 2026-06-05 | auto-007 run summary (no-number era) |
| `run-summary-auto-009.md` | `6739a8f6` | 2026-06-06 | auto-009 closeout |
| `run-summary-auto-010.md` through `auto-016.md` | various | 2026-06-06–2026-06-09 | One per unattended run |
| `run-envelope-auto-016.md` | `85aaf349` | 2026-06-08 | Scope envelope for auto-016 |
| `SUBSTRATE-READINESS.md` | `fdad8e65` | 2026-06-09 | Clean-build gate mandated after accountability retro |

[FACT] Two root files were **deleted** on 2026-05-28: `i-am-a-fucking-idiot.md` (PR #116, added 2026-05-27 as a 278-line distress handoff during the migration tail) and `handoff-recovery.md`. Both were swept by commit `01d18589` ("chore: delete stale handoff-shaped root files"). [cmd: `git show 01d18589 --stat`]

[FACT] Currently 19 root `.md` files remain in HEAD (`ls *.md | wc -l`). The pattern shows one summary file per autonomous run from auto-009 onward; earlier runs used date-named files.

[OPEN] `run-summary.md` (generic, no date or auto-NNN in name) was created 2026-06-05 by `docs(auto-007): run summary` but is still present at HEAD alongside the numbered files — unclear if it is canonical or orphaned.

---

## Notes on PR-Number Investigation

[FACT] The hint that "PR numbers may have reset around 2026-06-05" does **not** correspond to a numbering reset. PR #139 (2026-06-04) uses the old `from lago-morph/<branch>` format; PR #140 (2026-06-05) uses the new `: <title>` format. Numbers are strictly sequential with no reset. [cmd: merge message audit across all 184 merged PRs]

[INFERENCE] The format change at PR #140 is most likely a change in how `gh pr merge` or the GitHub merge UI was invoked, or a switch from "create merge commit" to a mode that produces a shorter subject line. The PR numbers themselves are a single unbroken GitHub sequence on the same repo.

[OPEN] PRs #2–#18 have no merge commit in git history (gap: 17 PRs). These may be GitHub issues (GitHub shares the issue/PR number namespace) or PRs that were closed without merging. Cannot be resolved from git alone; requires GitHub API query.

[OPEN] PRs #149–#152 are also absent from merge history (4 PRs between #148 and #153). Commits `159a7f53` (#149, 2026-06-05), `7fc740ff` (#150), `05fd1581` (#151), `1dd57cfe` (#152) exist as **direct commits to main** (not merge commits) — these were merged via fast-forward or squash without a merge commit subject line. [cmd: `git log --format="%H %ad %s" | grep "(#149)"` etc.]
