# auto-009 scope envelope — "to phase 6 clean"

Long-run delegated by the user 2026-06-06 ("Long run from here. Keep working
and good job."). This is the run contract; it is the first commit of the run
so the whole chain can be rewound to "before auto-009 began."

Live account this run: `211125540973` (us-east-1), fresh; GitHub-Actions
secrets verified working (phase-0 green, no `InvalidClientTokenId`).
`main` already carries the render-fix + version pins (#153) and the
phase-4/5 decisions (#154).

## 1. What I plan to do

- **Finish the live rebuild** on `211125540973`: phase-1 management
  (running now) → phase-2 chainsaw → phase-3 platform cluster + spoke,
  verifying `https://hello.platform.<domain>` returns 200 with valid TLS.
- **Land the auto-007 phase 3-6 stack to `main`** per the user's decision:
  `#144` trunk → `#145` phase-3-spoke → `#146` phase6 / `#147` phase4 /
  `#148` phase5 — each updated onto current `main` with a green
  `chainsaw-verify` on its head SHA (§6.7), merged in stack order.
- **Implement the recorded phase-4/5 decisions as code:** a `hub-addons`
  ArgoCD AppProject for the hub Alloy agent (Option A); a general
  `XDatabase` XRD + an RDS-backed Composition for the Keycloak database.
- **Finish the half-done maxPods / prefix-delegation** (pin
  `AL2023_x86_64_STANDARD`, confirm nodeadm `maxPods: 110` by decoding the
  launch-template user-data) before the phase 4/5/6 pod load lands — the
  pod-IP exhaustion that downed ingress-nginx in auto-007.
- **Drive phases 4/5/6 live** as far as the cluster allows; for each step
  state plainly whether it's provisioned/verified or blocked on
  verification access (§6.22).

## 2. What I plan to NOT do

- **No teardown / `terraform destroy`** of any phase — this run only builds
  up on the fresh account (§5 invariant 1).
- **No re-authoring of the auto-007 stack** from scratch — the user chose
  "land it," so I rebase + verify, not rewrite.
- **No changes to the Alloy or DB decisions** (locked: Alloy = Option A
  `hub-addons`; DB = general `XDatabase` XRD, RDS-backed).
- **No redesign of the phase 0/1 bootstrap** (ingress-nginx, ArgoCD, ESO,
  Crossplane core, ExternalDNS, Kyverno) beyond the maxPods/capacity fix.

## 3. Scale estimate

~12–20 stacked PRs (stack-landing updates, the 4/5/6 implementations,
maxPods, decision briefs, the run summary). Adversarial-review subagents:
≥3 per round × 2 rounds for each load-bearing decision brief, plus
test-plan review waves (§6.4). Wall-clock paced by CI: each phase apply
~15–20 min, each chainsaw ~15 min — I author 4/5/6 code and the
hub-addons/XDatabase manifests during those waits rather than idling.

## 4. First decision points (best answer / alternative / rewind)

1. **Stack vs. live AWS contention.** Best: **sequence** — finish live
   phase 1→2→3 first, then run the per-PR stack chainsaws, because chainsaw
   scenarios provision real ASM secrets in the same account and could
   contend with the live applies. Alt: parallelize and accept the risk.
   Rewind: sequencing only — no artifact to revert.
2. **maxPods finish needs a live node recycle** (disruptive to the running
   management cluster). Best: pin the AL2023 AMI + `maxPods: 110`, **decode
   the LT user-data first** (auto-007 trap: `enable_bootstrap_user_data`
   emitted an AL2 `bootstrap.sh` that would brick AL2023 nodes), apply in a
   quiet window after phase-1 verify. Alt: rely on 3×17≈51 pod slots and
   defer. Rewind: revert the `eks.tf` AMI/maxPods commit.
3. **`#144` `chainsaw-verify` is red on a scope-doc PR** — investigate why
   the gate triggers there; if it's an unavoidable required check, dispatch
   chainsaw on each stack SHA. Brief if the trigger is structural.
4. **`XDatabase` XRD shape** (RDS instance + subnet group + SG via the AWS
   provider, consumed by Keycloak through the abstraction). Decision brief
   with two adversarial rounds before authoring the Composition.

## 5. What I'll surface in the morning summary

- Live status of phases 1/2/3 (run IDs, green/red, verified URLs).
- Which stack PRs landed vs. blocked, with the chainsaw run URLs.
- Phases 4/5/6 state: authored / CI-green / live, and what's blocked on
  verification access vs. genuinely provisioned.
- The maxPods change and its node-recycle impact.
- Any decision briefs awaiting the user's ratification.

## 6. Stop conditions

- Context budget ~70% → write summary + retro now, continue if room.
- Hard auth / GitHub / jentic failure → `github-connection-resilience`
  recovery first; stop only if unrecoverable.
- A destructive operation would be required (out of scope) → stop + brief.
- A live apply hard-fails on a real account/quota decision (e.g. EC2 quota
  exhausted, a constraint silently missing per testing-guidelines §1) →
  brief + surface as a morning item.
- 30-PR cap, or scope-envelope completion (then prefer extending into
  adjacent in-scope work over stopping).
