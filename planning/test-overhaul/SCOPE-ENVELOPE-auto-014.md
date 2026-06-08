# Scope Envelope — auto-014 (unattended, user asleep)

> **Run:** auto-014 · **Date:** 2026-06-08 · **Mode:** autonomous-run (user
> structurally absent) · **Trunk branch:** `claude/test-overhaul-unattended-run-eWZgz`
> (sits exactly at `origin/main` = `ffd5d7d`, which already carries #190).
> **Authoritative spec:** `planning/test-overhaul/FINAL-PLAN.md` (§16 rollout) +
> ADR-0006 + `docs/testing-debt-burndown.md` item 4. This envelope is the
> fallback contract; the user is unreachable by definition, so the run begins on
> the envelope as written.

## 0. Sandbox reality (governs what "done" can mean tonight)

> **Correction (owner, mid-run):** my first draft wrongly called `kubectl` and
> Docker absent. AGENTS.md §6.12 already covers this; I should have installed
> them. Both now work and are wired into `scripts/sandbox-setup.sh` so no future
> session repeats the mistake. Envelope re-authored accordingly.

- **AWS creds work** (account `878302603783`) → the read-only *after*-tier
  checks are **genuinely exercisable** against the real account here, and I have
  already done so while authoring.
- **`kubectl` works** against both live clusters (`k8-platform-mgmt` hub,
  `k8-platform-services` spoke) through the SSM relay
  (`scripts/sandbox-kubeconfig.sh`), proven this run. It is **read-only** — the
  sandbox identity is mapped to `AmazonEKSAdminViewPolicy`; mutations go through
  ArgoCD/CI only. So I can read live XR/MR conditions and the ExternalSecret
  `Ready` state, but I **cannot** `kubectl apply`/`delete`.
- **Docker works** (`sudo dockerd &`) → `composition-render.sh` is available.
- **What this means for "done":** the read-only after-tier (Track A) is fully
  validatable here. The **mutating** instantiate (P4) and negative (P5) tiers
  *create/delete* resources, which the read-only sandbox identity cannot do;
  their live validation runs through CI/ArgoCD, so per AGENTS.md §6.35 they land
  **red-first / "pending clean-build verification"**, never "done", with the
  live run flagged as a morning item.

## 1. What I plan to do

- **STEP 0 — close the #190 round-trip.** `workflow_dispatch` `live-verify.yml`
  once (now that it is on `main`) via the GitHub MCP, confirm artifact
  upload → `live-evidence-gate` API-fetch end-to-end, and that a `crossplane/**`
  PR's `live-evidence-verify` flips GREEN on the fresh evidence. If broken, the
  fix is the first stacked PR (load-bearing for everything below).
- **TRACK A — 13 read-only "after"-tier behavioral checks**, one per `pending:P*`
  kind in `tests/coverage/registry.yaml` (acm ×2, eks ×4, iam ×4, route53 ×1,
  secretsmanager ×1, external-secrets ×1). Each is its kind's ADR-0006 oracle:
  proves the REAL cloud resource the Crossplane abstraction produced exists and
  is healthy, selected by the Composition's own stamp; exact rds contract
  (missing tooling/creds ⇒ skip; resource absent ⇒ skip→orchestrator promotes to
  expect-full FAIL; unhealthy ⇒ ng+exit1; healthy ⇒ ok+covers+exit PASS).
  Fan out to subagents (one file each). Flip each registry `defended_by` off
  `pending:P*`; **probe the live account first** to broaden `LIVE_EXPECT_FULL`
  ONLY to kinds actually provisioned (a declared-but-unprovisioned kind correctly
  goes RED — no green-washing). Validate on a CLEAN build: unit suite green,
  `pre-chainsaw-audit.sh` clean, `run.sh` exercised via the
  `LIVE_EXPECT_FULL`/`LIVE_CHECKS_ROOT` seams. Then run the LIVE producer once.
- **TRACK B — FINAL-PLAN P3, P4, P5**, ADR-0006-compliant, tests added/modified:
  P3 (account-mutex, reaper-runs-first friendly-fire-proofed, ArgoCD-excluded ns,
  throttle/quota classifiers, bounded teardown poll, synthetic-secret redaction);
  P4 (parametrized hermetic instantiate-and-verify harness proven on ASM Secret +
  global IAM Role, idempotency assertions); P5 (XRD/AppProject/RBAC/confused-deputy
  negatives that PROVE THE GUARD FIRED, hub-side spoke GitOps watch, app-level
  Keycloak-DB gate). Each P-phase closes as its own stacked PR, red-first where
  feasible.
- **Decision briefs (2 rounds, ≥3 real adversarial subagents each)** for the
  legitimate owner choices: the cost-tier assignments (§5/§14.5), the §14.3
  `Resource:"*"` tightening + deny tests (default: NOT tighten unless review is
  decisive), the conditional hub→spoke curl e2e (§14.2), and the spoke
  CIDR/AccessEntry allowlist.
- **Morning summary + full self-retrospective package + subscribe to every PR.**

## 2. What I plan to NOT do (boundaries — ADR-0006 NON-GOALS, hard)

- **No probe pod, no new AssumeRole principal, no IAM trust widening, no
  provider-SA token mount.** The verifier/reaper stays under the scoped
  zero-wildcard role. If a thread seems to need one, I STOP it and record it as
  a morning-review item (I do NOT brief it).
- **`LIVE_MODE=mutating` stays fail-closed off by default;** instantiate/negative
  tiers run only under `LIVE_PROFILE=full`.
- **No green-washing of `LIVE_EXPECT_FULL`** to dodge a RED for an unprovisioned
  kind. No `skip`-reads-green climb-down.
- **No retrofit of working resources** outside the test machinery.

## 3. Scale estimate

- **PRs:** target 14–24 stacked PRs (cap 30). Bottom = this envelope; top =
  morning summary + retrospective.
- **Subagents:** Track-A authoring fan-out (≤13 parallel, one file each) +
  decision-brief adversarial waves (≥3 × 2 rounds × 4 briefs) + P3/P4/P5
  authoring fan-out.
- **Duration:** full session. Long pole is the live-verify `workflow_dispatch`
  round-trip and any live producer runs (background while I author).

## 4. First decision points (best call now; alternative; rewind)

1. **How far to broaden `LIVE_EXPECT_FULL`** (Track A). *Call:* probe the live
   account read-only, broaden ONLY to kinds with a real provisioned resource;
   leave the rest declared-but-RED-correct or out of expect-full per provisioning
   reality. *Alt:* broaden to all 13 immediately (green-washes / wrongly REDs).
   *Rewind:* revert the expect-full edit in `live-verify-run.sh`.
2. **Cost-tier assignments** (§5/§14.5). *Call:* keep the registry's current
   tiers; brief any change. *Alt:* re-tier per a reviewer-driven model. *Rewind:*
   revert the registry PR.
3. **§14.3 `Resource:"*"` tightening + deny tests.** *Call (default):* do NOT
   tighten unless the two review rounds are decisive; document the gap. *Alt:*
   tighten incrementally + ship deny tests. *Rewind:* revert the tightening PR.
4. **§14.2 hub→spoke curl e2e + spoke CIDR/AccessEntry allowlist.** *Call:* brief
   it; default to the hub-side config + after-the-fact fallback unless the
   allowlist/AccessEntry path is confirmed. *Rewind:* config-only.

Each is handled via a decision brief (two adversarial rounds) when reached.

## 5. What I'll surface in the morning summary

- STEP 0 round-trip outcome (round-trip confirmed vs. fix-PR shipped).
- The 13 after-checks: which kinds verified GREEN against the real account here,
  which correctly SKIP (unprovisioned / no tooling), which are expect-full RED.
- The 4 decisions above with as-built resolutions + rewind paths.
- P3/P4/P5: what's authored + unit-validated vs. what's **pending clean-build
  (live-cluster) verification** — explicitly, no hiding deferrals.
- Any ADR-0006 NON-GOAL a thread bumped into (recorded, not briefed).
- Suggested merge order (stack-bottom first).

## 6. Stop conditions

- **Stop** on: context-budget approaching exhaustion (write summary + retro
  first); a hard-failed dependency (AWS/GitHub/MCP auth unreachable, after the
  `github-connection-resilience` recovery); 30-PR cap; a user message arriving.
- **Do NOT stop** for: a sub-phase closing (start the next); an ambiguous
  subagent result (write a follow-up brief); user-judgment territory (write the
  brief + run the rounds + pick a side + document rewind).

---

*Rewind point for the whole run: revert this PR's chain to return to pre-run
`main` (`ffd5d7d`). Revert from the second PR onward to keep the envelope but
undo the work.*
