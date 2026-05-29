# Scope envelope — `auto-004` "implement phase 2 — make the Crossplane XRDs work"

**Author.** Lead agent, autonomous-run session 2026-05-29.
**Status.** Awaiting user confirmation (implicit-confirm after a short wait — user is away on an overnight run).

This document aligns intent before the unattended run begins. The morning
user reviews against this envelope.

## Context (what the user asked)

> "I want you to implement phase 2 of the kubernetes cluster. The crossplane
> XRDs were not working last time we tried this."
> "this is an overnight run"

Phase 2 = **Crossplane Foundations** (DESIGN.md §Iteration 2):
`PlatformSecret` XRD/Composition proven end-to-end, `PlatformCluster`
XRD/Composition defined (not yet invoked), ClusterSecretStore, ArgoCD
GitOps of `crossplane/`. The handoff marks phase 2 `verified`, but the
user reports the XRDs "were not working," and the repo carries concrete
evidence of that: `OI-2026-05-28-1` (chainsaw `composition-drift`
failures) and **missing SPEC-S9 render goldens** — both
`crossplane/xrds/*/render-fixtures/` dirs have `input.yaml` but no
`expected.yaml`, so the author-time render check has never actually run
against these Compositions.

## What I plan to do

- **Stand up local Crossplane tooling in-sandbox** (start dockerd, install
  `crossplane` CLI + `kind` + `kubectl` + `helm` + `kubeconform`) so the
  XRDs/Compositions can be validated offline — Docker is installed and
  egress to releases.crossplane.io returns HTTP 200.
- **Run `crossplane render` for both Compositions** against their
  render-fixtures, fix any render bug it surfaces (the most likely home of
  "XRDs not working"), and commit the generated `expected.yaml` goldens —
  closing the mandatory SPEC-S9 deliverable for `platform-secret` and
  `platform-cluster`.
- **Fix `OI-2026-05-28-1` Issue B** — the `composition-drift` cleanup
  re-applies `crossplane/compositions/platform-secret.yaml` via a
  CWD-relative path under `|| true`; the path never resolves and the mask
  cascades three downstream scenario failures. Resolve the path absolutely
  and drop `|| true` (AGENTS §6.19), with a regression test (§6.2).
- **Boot a local kind cluster + Crossplane (no AWS)** and run the offline
  chainsaw scenarios (`xrd-establishes`, `_smoke`, `meta-catch-fires`) to
  prove the v2 XRDs Establish and the CRDs land — the "do the XRDs work"
  check that needs no AWS account.
- **Run the full local gate** — `scripts/pre-chainsaw-audit.sh`,
  `tests/unit/run.sh`, kubeconform — and fix every FAIL, regenerating the
  kubeconform schema store if a version/XRD change requires it.
- **Strengthen PlatformCluster coverage** — render golden + a chainsaw
  `resourceRefs`-shape assertion (offline) that the Composition emits all 8
  expected managed resources (brainstorm A3-038), with §6.4 adversarial
  review of the test plan via real subagents.
- **Dispatch `chainsaw.yml` to CI** for the real-AWS verification per
  §6.7/§6.8; iterate to green if AWS creds are live, or document
  credential staleness per §8.2 and defer the AWS leg if they are not.
- **Update `ai/handoff.md`, `docs/open-issues.md`, write
  `overnight-summary.md`, and run the self-retrospective.**

## What I plan to NOT do

- I will **not** begin phase 3 (platform-services cluster, ApplicationSet
  kubeconfig repoint, ingress/DNS/cert-manager). PlatformCluster stays
  "defined, not invoked" per DESIGN §Iteration 2.
- I will **not** run `terraform apply`/`destroy` on phases 0/1 or touch the
  management bootstrap stack — phase 2 teardown/rebuild is GitOps-only
  (PHASE-2-LIFECYCLE-PLAN §B), and §5 invariant 1 forbids touching lower
  phases.
- I will **not** rotate or fabricate AWS credentials; if CI creds are stale
  I document and defer the real-AWS leg rather than chase code fixes on an
  environmental failure (§8.2).
- I will **not** chase `OI-2026-05-28-1` Issue A (first-run XR-Ready >245s)
  to a root cause if it needs many real-AWS chainsaw dispatches — I'll
  improve its diagnostics and leave it tracked.

## Scale estimate

- **Target PR count:** **1** PR on the designated branch
  `claude/fervent-ride-cPkqa`, organized as logically-grouped commits.
  *Deviation from the skill's 20-30 stacked-PR default:* the harness task
  instructions say develop on `claude/fervent-ride-cPkqa` and "NEVER push
  to a different branch without explicit permission," which overrides the
  multi-branch stacking. Each commit is independently revertable; the PR
  description indexes them.
- **Subagent count estimate:** 6-10 (two §6.4 adversarial test-plan review
  waves of ≥3 real subagents, plus targeted research/explore).
- **Expected duration:** a full overnight run (several hours of live
  work + local kind/chainsaw boots + any CI chainsaw dispatch wait).

## First decision points

1. **Does the user accept a single-branch single-PR shape instead of
   stacked PRs?**
   - **Lead-agent current best:** single branch `claude/fervent-ride-cPkqa`,
     because the harness branch policy is explicit and load-bearing.
   - **Alternative:** stacked PRs (skill default) — would require pushing
     new branches, which the policy forbids without explicit permission.
   - **If you disagree:** tell me to stack; I'll split per the skill.
2. **If `crossplane render` reveals a real Composition bug, fix it in this
   run?**
   - **Lead-agent current best:** yes — that *is* "the XRDs not working";
     fixing it is the heart of the task. Each fix lands with its render
     golden as the regression artifact.
   - **Alternative:** report-only. Rejected — the user asked me to make
     them work.
   - **If you disagree:** revert the relevant `fix(crossplane/...)` commit.
3. **How far to push the real-AWS chainsaw leg if CI creds are stale?**
   - **Lead-agent current best:** verify offline fully in-sandbox, dispatch
     chainsaw once to CI, and if it fails on `InvalidClientTokenId` /
     `CannotConnectToProvider` (§8.2 shapes) document it as
     environmental + defer, not chase code.
   - **Alternative:** keep re-dispatching. Rejected — wastes runner minutes
     on an environmental failure.
   - **If you disagree:** I can re-dispatch once creds are rotated.

## What I'll surface in the morning summary

- The `crossplane render` outcome for both Compositions — pass, or the
  specific bug found + fix (this is the likely "XRDs not working" answer).
- The real-AWS chainsaw leg status: green, or deferred-as-environmental
  with the verbatim error.
- `OI-2026-05-28-1` Issue A status (expected to remain tracked, not closed).
- Any PlatformCluster test-scope judgment calls from the §6.4 review.

## Stop conditions

- **Allowed stops:** context-budget approaching exhaustion, hard-failed
  dependency (Docker won't start, egress blocked, GitHub/auth down),
  scope-envelope completion, user-message interrupt.
- **Will NOT stop on:** a sub-task closing, an ambiguous subagent result, or
  a decision that feels like user-judgment territory (decision briefs +
  adversarial review handle those).

---

## User response (filled in by user, or left blank for implicit-confirm)

- **Confirm as-written:** _(blank — implicit-confirm)_
- **Adjustments:** _(none yet)_
- **Implicit-confirm after wait:** yes (proceeding; user is away).
