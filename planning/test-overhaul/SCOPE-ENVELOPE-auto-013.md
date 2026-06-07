# Scope Envelope — auto-013 (overnight, unattended)

> **Run:** auto-013 · **Date:** 2026-06-07 · **Mode:** autonomous-run (overnight,
> user structurally absent) · **Trunk branch:** `claude/blissful-faraday-RsPY2`
> **Authoritative spec:** `planning/test-overhaul/FINAL-PLAN.md` (PART I spine +
> §16 phased rollout). This envelope is the fallback contract; the user is
> unreachable by definition, so the run begins on the envelope as written.

## 1. What I plan to do

- **Bring up the substrate on the fresh account** (`695454131301`): terraform
  phases 0→1 then the phase-3 platform cluster, via `workflow_dispatch` of
  `terraform-test.yml` dispatched through the jentic/`ext-github` path. The
  auto-012 8-blocker fixes are in `main`, so the chain should not recur.
- **Front-load the P0 SPIKE** (FINAL-PLAN §16): prove the real v2/Pipeline/IRSA
  mechanism end-to-end on the live hub — `source: IRSA`, v2 composed-MR
  enumeration via `spec.crossplane.resourceRefs`, and that driving a real claim
  surfaces a real missing-permission as a real `AccessDenied`. If the core
  assumptions don't hold, STOP and write a decision brief — do not build on a
  broken mechanism.
- **Ship the FINAL-PLAN §16 rollout as stacked PRs**, front-loading P1 (the
  cluster-independent static scaffold: Pipeline-mode coverage deriver +
  byte-identical fixture test; the static wired/gating/scoped/on-by-default
  lints; `tests/live/run.sh` skeleton with the exit-code contract, `LIVE_PROFILE`
  selector and `expect-full`-from-git floor; the FAIL-closed live-evidence gate;
  the `compute-gates.sh` `mgmt_apply⇒verify` change; the committed zero-wildcard
  scoped verifier/reaper IAM policy). Then P2 (deepen after-the-fact), P3
  (isolation/reaper/redaction), P4 (instantiate-and-verify under real IRSA), P5
  (negatives + spoke trigger), P6 (hardening) — **as far as budget allows**.
- **Couple every new verification to the component it covers** (the whole point):
  a build step isn't done until its verification passes against the real cluster.
- **Keep `ai/handoff.md`, `docs/open-issues.md`, and a run-summary current**;
  write the morning summary + self-retrospective at the end.

## 2. What I plan to NOT do (boundaries)

- **No probe pod, no new AssumeRole principal, no trust-policy widening, no
  provider-SA token mount** — the FINAL-PLAN security NON-GOAL is absolute. The
  only identity oracle is driving the real controller under `source: IRSA`.
- **No `skip`-reads-green climb-down.** All-skipped ⇒ RED, per profile; the
  live-evidence gate stays FAIL-closed (never demoted to WARN).
- **No cluster-requiring workflow on push/PR.** All cluster work stays
  `workflow_dispatch`-only; workflow edits land via jentic.
- **No retrofit of working `XPlatformSecret` usages** (ADR 0005 — ESO is the
  default; XPlatformSecret is forward-looking only).

## 3. Scale estimate

- **PRs:** target 12–24 stacked PRs (cap 30). Bottom of stack = this envelope;
  top = morning summary + retrospective.
- **Subagents:** decision-brief adversarial waves (≥3 reviewers × 2 rounds per
  brief) + parallel authoring fan-out for independent P1/P2 test modules.
- **Duration:** full overnight. The EKS bring-up (~20+ min/cluster) is the long
  pole and runs in the background while I author cluster-independent static code.

## 4. First decision points (best call now; alternative; rewind)

1. **Scoped verifier/reaper IAM role** (§14.7). *Call:* stand it up (zero-wildcard,
   tag-conditioned, committed `.tf`/JSON). *Alt:* run verifier under admin
   (rejected — that is the new hole correction #2 opened). *Rewind:* revert the
   IAM-policy PR.
2. **Tighten `Resource:"*"` on IAM/RDS** (§14.3) toward derived verb lists so deny
   tests have teeth. *Call:* tighten incrementally, never breaking provisioning;
   where risky, keep the deny test documented-deferred rather than weakening
   provisioning. *Alt:* decline + drop deny tests (documented gap). *Rewind:*
   revert the tightening PR (deny tests drop with it).
3. **Spoke public-endpoint CIDR allowlist + CI AccessEntry** (§14.2). *Call:*
   confirm/extend at spike time so the runner reaches the spoke kube-API. *Alt:*
   CloudTrail-proxy + hub-side config fallback (§13). *Rewind:* config-only.
4. **ArgoCD controller role empty `role_policy_arns={}`** (task decision 4). *Call:*
   investigate; add the spoke-registration policy if the registration path needs
   it. *Alt:* leave as-is if registration works without it. *Rewind:* revert the
   terraform PR.

Each is handled via a decision brief (two adversarial rounds) when reached, not
by blocking overnight.

## 5. What I'll surface in the morning summary

- P0 spike outcome (mechanism confirmed vs. shape-change brief).
- The 4 decisions above with their as-built resolutions + rewind paths.
- Any deny tests left documented-deferred (and why).
- Live bring-up status (which phases verified green) and any new live blockers.
- Suggested merge order for the stack.
- Explicit "what I deliberately did NOT do" / carried-forward phases.

## 6. Stop conditions

- **Stop the run** on: context-budget approaching exhaustion (write summary +
  retro first); a hard-failed dependency (auth/jentic/GitHub unreachable, after
  the resilience recovery); the P0 spike disproving the core mechanism (write the
  shape-change brief and stop building on it); 30-PR cap; a user message arriving.
- **Do NOT stop** for: a sub-phase closing (start the next); an ambiguous
  subagent result (write a follow-up brief); user-judgment territory (write the
  brief + run the rounds + pick a side + document rewind).

---

*Rewind point for the whole run: revert this PR's chain to return to pre-run
`main` (`ef10ce1`). Revert from the second PR onward to keep the envelope but
undo the work.*
