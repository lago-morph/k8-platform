# Overnight run summary — auto-004 (2026-05-29)

**Goal (user):** "Implement phases 2, 3, 4… on the AWS cluster. The Crossplane
XRDs were not working last time." Overnight, stacked PRs, no PR cap.

## TL;DR

- **Phase 0 (base): VERIFIED on a fresh account** — `Apply complete! 25 added`; live-confirmed VPC, 2 NAT GWs, Cognito pool, ISSUED ACM wildcard cert, tfstate bucket.
- **Phase 1 (management): VERIFIED** — apply-and-verify GREEN; EKS `k8-platform-mgmt` ACTIVE (v1.35). (Sandbox can't kubectl the endpoint — environmental; CI's in-cluster verify passed.)
- **Phase 2 (XRDs): VERIFIED on real AWS.** The real "not working" cause: the SPEC-S9 author-time render check had **never run** (no goldens existed) due to a determinism bug in the render helper. Fixed → both Compositions render-validate (12/0). Real-AWS chainsaw: first run 5/6 (`claim-rotation` flaked — OI Issue A); **re-kick PASSED full set** ([run 26622175855](https://github.com/lago-morph/k8-platform/actions/runs/26622175855), all scenarios green against `71022db`) → confirms the flake hypothesis. **PR #132 is now fully green (chainsaw + unit tests) and mergeable.**
- **The account was freshly rotated** (empty) — the handoff said phase 0/1 were verified, but that was the prior account. Added **AGENTS §8.4** so future sessions assume an empty account until the live API proves otherwise.
- **Phase 3 planned, not started** — gated on phase 1/2 green; the entry blocker (D1: subnet tag-selector, §8.1) and the empty platform-services stack are documented in `decisions/auto-004-phase-3-plan.md`.

## Suggested merge order

1. **PR #132** (`claude/fervent-ride-cPkqa` → `main`) — stack base. Phase-2 render-determinism fix + goldens + AGENTS §8.4 + open-issues updates. **Merge once its chainsaw-verify check is green** (depends on the re-kicked chainsaw run passing; see Morning-review #1).
2. **`claude/auto-004-phase-3`** (→ `main` after #132) — phase-3 plan doc only (DRAFT). Safe to merge or leave until phase 3 starts. No PR opened yet (docs-only).
3. **`claude/auto-004-summary`** (this branch, → `main` after #132) — this summary + handoff update. Merge last.

## PRs opened (stack order)

| PR | Branch | Title | Base | Status | Rewind |
|----|--------|-------|------|--------|--------|
| #132 | `claude/fervent-ride-cPkqa` | auto-004 (stack base): phase-2 XRD render validation + fresh-account rule | `main` | Open; unit-tests green, chainsaw-verify gated on re-kick | revert `af283cc` (envelope), `1e4bc94` (render fix+goldens), `02c62f9` (§8.4) |
| — | `claude/auto-004-phase-3` | (no PR yet) phase-3 plan | `main` | pushed | revert `e0e75a9` |
| — | `claude/auto-004-summary` | (this) summary + handoff | `main` | about to open | revert this branch |

## Decision briefs / planning docs

| Doc | Summary |
|-----|---------|
| `decisions/auto-004-scope-envelope.md` | Run scope; expanded mid-run to stacked PRs + phases 2-6. |
| `decisions/auto-004-phase-3-plan.md` | Phase-3 plan; 4 decisions flagged (D1 subnet selection is the blocker). No adversarial rounds run yet (gated on phase 1/2). |

## Chain status

- Phases 0+1: live on account (query ID via `aws sts`). Phase 2: code + offline gate done; real-AWS confirmation pending the chainsaw re-kick.
- Phase 3: planned only. First action = D1 decision brief (2 rounds, ≥3 real reviewers) on subnet selection, then a phase-0 terraform tag add, then provision the platform cluster.

## Morning-review items

1. **chainsaw `claim-rotation` flake (OI Issue A) — RESOLVED for this run.** Re-kick against `71022db` passed the full set, confirming a transient flake (not a Composition bug). #132 is green. *Durable follow-up (not blocking):* OI Issue A should still get a permanent fix so it stops flaking — recommended: set `crossplane.io/external-name` on the ASM secret MR so the provider adopts the existing secret instead of re-issuing CreateSecret (alt: run chainsaw scenarios serially). Tracked in `docs/open-issues.md`.
2. **Phase 3 D1 — subnet selection design.** Recommendation: tag-based `subnetIdSelector` + add a dedicated `subnet-tier=private` tag in `terraform/base` (the private subnets currently differ from mgmt/public only by `Name`). Needs your nod before I change the base module. Full options in the phase-3 plan.
3. **Sandbox cannot kubectl the mgmt EKS endpoint** (TLS/egress). Not blocking (CI verifies in-cluster), but phase-3 cluster checks will go through CI/ArgoCD, not sandbox kubectl. FYI.

## What I deliberately did NOT do

- Did **not** start phase 3 implementation (provisioning a 2nd EKS cluster, authoring the platform stack) — gated on phase 1/2 green + the D1 decision, which is yours.
- Did **not** run `terraform destroy` or touch phases 0/1 beyond bring-up (§5 invariant).
- Did **not** chase OI Issue A to root cause with repeated real-AWS chainsaw dispatches — recorded the new evidence and re-kicked once (per scope envelope).
- Did **not** fabricate/rotate creds — you pasted fresh keys mid-run; they live only in `/tmp` + `~/.aws` (never committed).

## Rewind points

| SHA | Undoes |
|-----|--------|
| `af283cc` | scope envelope (before-run anchor) |
| `1e4bc94` | SPEC-S9 render determinism fix + both goldens |
| `02c62f9` | AGENTS §8.4 fresh-account rule |
| `71022db` | open-issues Issue A recurrence note |
| `e0e75a9` (phase-3 branch) | phase-3 plan doc |

## Session metadata

- Branches: `claude/fervent-ride-cPkqa` (#132 base) → `claude/auto-004-phase-3` (plan) → `claude/auto-004-summary` (this).
- Account: freshly rotated this session (ID ephemeral; query `aws sts`). Region us-east-1.
- Key runs: phase-0 `26621367469` (success), phase-1 `26621556820` (success), chainsaw `26621695077` (5/6, claim-rotation failed), chainsaw re-kick against `71022db` (pending).
- Tooling installed in-sandbox: crossplane CLI v2.3.1, kind, kubectl, helm, kubeconform, mikefarah yq, aws CLI v2, dockerd.
