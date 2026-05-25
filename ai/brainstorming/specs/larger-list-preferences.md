# Implementing-agent preferences — full brainstorm.md selection

**Author:** implementing agent (Claude), 2026-05-25 session wrap
**Source:** `ai/brainstorming/brainstorm.md` (400 ideas across A1-A6)
**Context:** the next session has full network access + `aws` CLI from the
sandbox. Picking which brainstorm items would do the most to make phases
2 → 6 smoother, faster, and higher quality.

This file is the longer companion to
`ai/brainstorming/specs/preferences.md` (which focused on the 15 specs in
`ai/brainstorming/specs/SPEC-*.md`). Both prioritization lists are my
preferences as the agent who has to use the resulting tools; the user may
weight differently.

---

## Selection criteria

Each item evaluated on five axes:

1. **Multiplier effect** — does it make N other ideas easier or obsolete?
2. **Cross-phase reach** — only phase 2, or phases 2-6?
3. **Documented bug-class coverage** — has the bug actually bitten us, repeatedly?
4. **Wall-clock saved per inner debug loop** — minutes saved per iteration?
5. **Effort** — small (≤1 hr), medium (1-3 hr), large (>3 hr)?

A spec earns a high tier only when (1) or (3) is strong AND (5) is
small/medium. The list explicitly **excludes** items where I assess
implementation effort to be on the same order as projected time saved.

### Apples-to-apples — implementation IS debugging time

Both implementation and debugging will be done by the same AI agent.
Implementation hours and debugging-hours-saved are measured in the same
currency (agent wall-clock + context-window cost). This actually
strengthens the case for high-prevention items:

- A **static lint** that prevents a bug entirely is strictly better than
  a **debug tool** that helps diagnose the bug once it occurs — even if
  both cost the same to build. The lint saves the full debug cycle plus
  the context-window thrashing that comes with reactive debugging.
- A **3-hour skill build** that prevents one 3-hour debug session is
  break-even on wall-clock, but **positive** on context-window cost (the
  build runs once on a clean context; the debug session would burn
  context that has to be re-derived next session).
- **Compounding multipliers** (S2 used every phase 2-6 claim) dominate
  one-shot wins. The hour-for-hour math undercounts these.

The list below applies a 1.5× implicit weight to prevention vs reaction,
and a 2× implicit weight to items used in phases 2 through 6 vs single-phase
items.

---

## TL;DR sequencing

| Tier | Count | Total effort | Sessions to break-even |
|---|---|---|---|
| Tier S — multiplier primitives | 10 items | ~17 hours | <3 sessions |
| Tier A — chainsaw + debug acceleration | 8 items | ~12 hours | <5 sessions |
| Tier B — regression corpus + static lints | 8 items | ~10 hours | <8 sessions (B1+B2+B6 break even in 1) |
| Tier C — observability foundations | 6 items | ~8 hours | <12 sessions (compounds in production) |
| Tier D — cruft removal that unlocks parallelism | 5 items | ~4 hours | next session |

**Recommended order under apples-to-apples**: S → D → B1+B2+B6 → A → rest of B → C.

Build primitives first. Then the cheap cruft-removal wins. Then the
cheapest static lints (B1, B2, B6 — each ~1 hour, each prevents a
multi-session bug class). Then debug accelerators. Then defer-as-needed.

---

## Tier S — multiplier primitives (build first, before any other spec)

These ten items are the load-bearing primitives. Every later spec gets
cheaper once they exist. Used in every session, every phase.

### S1. SPEC-A4 — chainsaw `catch:` hook (from spec list)
**Effort:** ~2 hours. **Saves:** 5 min × every chainsaw failure × dozens of sessions = 20+ hours over project life.

Every chainsaw failure currently requires parsing a 245-second timeout log to find the actual cause. A catch hook that dumps `kubectl get events`, `kubectl describe xr`, provider logs, ESO logs on any step failure means each red iteration is diagnosable in seconds. This was Tier 0 in `preferences.md` and remains the highest direct ROI for the next session.

### S2. A1-019 — `scripts/crossplane-trace.sh <claim>`
**Effort:** ~3 hours. **Saves:** ~45 min per phase 2/2b/3 debug session.

Walks claim → XR → resourceRefs → MRs → atProvider, printing `.status.conditions` at each layer. PRs #66+#67+#68 (the IRSA cascade) and Bug 3 in this session would each have been minutes instead of multi-session debugging. Used by phase 2, 2b (PlatformCluster), 3 (workload clusters), 4 (observability), 5 (auth), and 6 (multi-cluster). **The single highest-leverage tool in the entire brainstorm.**

Combine with the `--watch` mode from A4→A1-019 (re-print every 10s) and the JSON snapshot mode from A3→A1-003.

### S3. A1-018 — `scripts/irsa_trust_validator.py --all`
**Effort:** ~2 hours. **Saves:** prevents the Bug 5 class permanently (already cost ~6 hours in one prior session).

For every IRSA role: fetch trust, decode OIDC provider, print expected `sub` claim, list matching SAs in cluster, MATCH/MISMATCH per role. The `--all` fleet-sweep mode (A4 cross-comment) is critical — Bug 5 manifested across multiple roles and per-role invocation misses the pattern.

IRSA is the #1 recurring bug class in this project; every phase adds new IRSA roles. This catches the SA-name drift class at its source.

### S4. A1-001 — `scripts/whereami.sh --json`
**Effort:** ~1 hour. **Saves:** 5 min × every session start = compounds across every session.

Prints account ID, region, EKS name, zone, kubectl ctx, ArgoCD URL, Crossplane version. With `--json` mode it doubles as a precondition gate for e2e tests (A2 comment). Used at every session start; eliminates 5 separate `aws`/`kubectl` invocations.

### S5. A1-002 — `scripts/phase-status.sh`
**Effort:** ~2 hours. **Saves:** 5-10 min per session of "is the handoff right?" reconciliation, plus catches stale handoff bugs.

Walks phases 0-6 and prints state (`not-coded` / `code-only` / `applied` / `verified`) by **probing live resources, not the handoff**. AGENTS.md §8.1 says treat handoff as belief not ground truth — this provides the ground truth. Also doubles as a chainsaw assert oracle (A2 comment) and the input to A1-034 (handoff-update.sh).

### S6. A1-058 — Pre-commit `kubeconform` against registered CRDs
**Effort:** ~1 hour. **Saves:** 10 min × every chainsaw iteration on YAML errors = compounds.

Catches Composition string-transform-missing-type (Bug 4 class), invalid manifests, missing required fields at commit time instead of chainsaw-iteration time. Extending to verify against function input schema (A3 comment) catches a distinct silent-failure class.

### S7. A1-021 — `scripts/wait-for-claim.sh <kind> <name> [ns] [timeout]`
**Effort:** ~2 hours. **Saves:** deduplicates ~10 bespoke `until kubectl get ... ; do sleep` loops AND catches silent-pass class (PR #59).

Becomes the canonical wait primitive used across every integration test, every chainsaw scenario, every probe. On timeout it auto-dumps last-seen conditions + composition events + recent events ±5 min (per A4→A1-021 quote-on-timeout extension). Pairs with A3-042 (canonical wait_for library) — same helper, two callers.

### S8. A1-006 + A1-007 — CloudWatch Logs Insights saved queries
**Effort:** ~1 hour combined (assuming Tier C foundations are in place).

`A1-006`: AssumeRoleWithWebIdentity failures last 1h, grouped by role + SA subject. Canonical IRSA-misconfig signature.

`A1-007`: EKS audit log denies grouped by user/group/verb last 1h. RBAC misconfig in 5 seconds.

Together these collapse two of the three most common "why doesn't it work" diagnoses into 5-second deep-link queries.

### S9. A1-040 — Composition render dry-run helper
**Effort:** ~2 hours. **Saves:** catches Bug 4 class (string transform missing `type: Format`) and other function-input bugs at author time, not chainsaw time.

Runs `crossplane render` locally against a claim + composition + function. With the fixture directory extension (A3 comment), every Composition has an expected rendered output checked into git — Bug 4 becomes a permanent guard. Critical for phase 2b (PlatformCluster) and beyond where Compositions get more complex.

### S10. A4-013 — `runbook-apply-zero-resources.md`
**Effort:** ~30 minutes. **Saves:** prevents recurrence of the PR #67 silent no-op class.

Documents the "Apply complete: 0 added" silent-no-op class with the `triggers_replace` hash-the-manifest pattern from PR #67. Three independent failures in one session per the handoff "It applied successfully ≠" lesson. The highest-leverage runbook in the repo. Pair with the static lint at S3 in Tier B for defense in depth.

**Tier S total effort:** ~17 hours. **Sessions to break-even:** approximately 3-5 sessions through phase 2 alone.

---

## Tier A — chainsaw + debug acceleration (build after Tier S)

These accelerate the current debug loop directly. Each is ≤3 hours and pays back within 5 sessions.

### A1. A1-039 — `scripts/crossplane-version-report.sh`
**Effort:** ~1 hour.

Prints Crossplane core, every Provider, every Function, every DeploymentRuntimeConfig binding, every provider package version. Version-skew bugs (this session's Bug 3 — provider v1.12.0 slow under 2.3.0 core) are silent until they bite. One command surfaces the whole version landscape. Will pay back during the very next session when bumping provider versions for Bug 3 fix.

### A2. A1-028 — `scripts/eso-trace.sh`
**Effort:** ~2 hours.

Walks ExternalSecret → ClusterSecretStore → AWS ASM Secret → IRSA role → fetched value (redacted). ESO has 6 ways to fail; this collapses them. With the `--decode-token` extension (A4 comment) it also surfaces IRSA mismatches — folds A1-047 into one ESO-debug call.

### A3. A1-029 — `scripts/kyverno-decision-explain.sh`
**Effort:** ~2 hours.

Simulates Kyverno admission on a YAML and prints which policies pass/fail and why. Phase 2 had ClusterPolicy 09 drift (Bug 3 from PR #64) that recurred across multiple sessions; this surfaces the policy-decision logic immediately.

### A4. A1-038 — `scripts/diff-state.sh phase=N`
**Effort:** ~2 hours.

Compares `terraform plan` output to live cluster state and highlights drift. Directly addresses the "Apply complete: 0 added" silent-no-op bug class. Pairs with Tier B's manifest-hash lint as the runtime equivalent.

### A5. A1-033 — `kubectl k8p <subcmd>` krew-style wrapper
**Effort:** ~2 hours.

Single discoverable surface for the project's debug commands (status, claim, secret, irsa, syncwave, eso-trace). Lowers cognitive cost; one command, many backends. Per A6 comment, supersedes the README "common commands" section.

### A6. A1-056 — `scripts/crossplane-reset-provider.sh <provider>`
**Effort:** ~1 hour.

Codifies the PR #68 hack (delete provider Deployment + wait for Crossplane to re-render) as one command. Already needed if Bug 3 fix involves provider version bumps; saves remembering the steps each time.

### A7. A1-043 — `scripts/argocd-syncwave-view.sh <app>`
**Effort:** ~1 hour.

Prints resources in sync-wave order with status. Sync-wave bugs in phase 2a were painful; this surfaces ordering directly. Phase 3+ will introduce more multi-wave apps and the ROI grows.

### A8. A1-031 — `scripts/r53-watch.sh <name>`
**Effort:** ~1 hour.

Polls Route53 record changes until propagation is confirmed via authoritative dig (not public recursors — those lie for minutes). ExternalDNS races are the #2 ingress bug. Already a recurring pain point; phase 5 (Keycloak ingress) and phase 6 (workload cluster ingresses) will hit this repeatedly.

**Tier A total effort:** ~12 hours.

---

## Tier B — regression corpus + static lints (catches future bugs)

These prevent bug-class recurrence. Each is small but defends a documented past failure permanently.

### B1. SPEC-B3 — `terraform_data` manifest hash lint (from spec list)
**Effort:** ~1 hour.

Catches the PR #67 silent no-op class at author time. Already detailed in `preferences.md`.

### B2. SPEC-B2 — IRSA SA-pinned lint (from spec list)
**Effort:** ~1.5 hours.

Catches the Bug 5 SA name drift class. Already detailed in `preferences.md`. Combines with A3-018 + A3-019 per A6 cross-comment.

### B3. A2-005 + A2-006 — Bidirectional IRSA invariant tests
**Effort:** ~2 hours combined.

A2-005: every IRSA role's trust subject must match an existing SA. A2-006: every SA's `eks.amazonaws.com/role-arn` annotation must point at a role whose trust contains its (ns, name). Bug 5 caught both directions; this locks both. Pairs with B2 above (static lint) for layered defense.

### B4. P→A2-003 — Bug regression corpus directory
**Effort:** ~1 hour scaffold + ~15 min per past bug to backfill.

`tests/regression/` directory: every retro'd bug gets a one-file reproducer that runs in CI. Turns institutional memory of past bugs into permanent guardrails. Bug 4 (string transform), Bug 5 (SA name), PR #59 ($UID shadowing), PR #67 (manifest hash) are immediate candidates. Compounds over project life.

### B5. P→A2-007 — Manifest hash drift test
**Effort:** ~1 hour.

Mutates the body of a manifest controlled by `terraform_data.triggers_replace` without bumping the trigger and asserts the diff is detected. Runtime regression for PR #67; pairs with B1 (static lint) as defense in depth.

### B6. A3-019 — DeploymentRuntimeConfig SA pinned lint
**Effort:** ~1 hour.

Asserts `DeploymentRuntimeConfig.spec.serviceAccountTemplate.metadata.name` is non-empty for every Crossplane provider using IRSA. Direct defending lint for Bug 5 / PR #66. Combines into a single "IRSA binding integrity" suite with B2/B3 (A6 comment).

### B7. A3-031 — UID-shadowing integration test
**Effort:** ~1.5 hours.

Creates two PlatformSecret claims in different namespaces with the same name; asserts no ASM key collision. UID-shadowing bug PR #59 root cause; runtime defense. Pairs with the static lint at A1→A3-012 (every ASM-writing Composition uses `${xr.metadata.uid}`).

### B8. A3-058 — Kyverno apiVersion + fail-open lint
**Effort:** ~1 hour.

Asserts every Kyverno ClusterPolicy uses `apiVersion: kyverno.io/v1` consistently AND `failurePolicy: Fail` is intentional with an annotation. Catches API drift (cheap) and fail-open misconfig (silent-half-brick — the worst kind).

**Tier B total effort:** ~10 hours.

---

## Tier C — observability foundations (set up once, query forever)

These are mostly terraform additions that enable the saved Logs Insights queries in Tier S. Small effort, but they unlock S8 and dozens of downstream alarm/dashboard ideas.

### C1. A1-005 — CloudTrail to dedicated CloudWatch log group, 7-day retention
**Effort:** ~30 minutes terraform addition.

Post-mortem any IAM/API failure with a single Logs Insights query. Essential foundation for S8 and for every "what did the agent actually do" question. Sandbox-cap-safe (7-day retention).

### C2. A1-003 — Enable EKS control-plane logging (api, audit, authenticator, controllerManager, scheduler)
**Effort:** ~30 minutes terraform addition.

Authenticator/audit logs are the only way to debug IRSA & RBAC denials post-hoc. Foundation for S8's `A1-007` query. Without these, every IRSA/RBAC debug becomes a guess.

### C3. A1-004 — Enable VPC flow logs to CloudWatch, 7-day retention
**Effort:** ~30 minutes terraform addition.

NAT/SG/route bugs are invisible without flow logs; cheap insurance. Phase 5 (Keycloak ingress through ALB) and phase 6 (cross-cluster traffic) will need this.

### C4. P→A1-006 / A1-054 — Auto-tagging policy (`k8platform-phase`, `k8platform-component`)
**Effort:** ~1 hour Terraform refactor (`default_tags` per provider block).

Enables per-phase CloudWatch / cost / drift queries to scope to the phase being worked on. Unlocks SPEC-C3 (tag check) and SPEC-C5 (drift integration test). Prerequisite that's small and standalone.

### C5. A1-070 — `scripts/cleanup-orphans.sh`
**Effort:** ~2 hours.

Lists AWS resources tagged `managed-by=k8-platform` but not referenced by terraform state or any Crossplane XR. Sandbox-kill prevention; the worst class of failure (lose the account, lose the session). Pair with C4 auto-tagging — the script needs the tags to work.

### C6. A1-014 + A1-015 + A1-016 — Three CloudWatch dashboards (k8-platform overview, IRSA debug, Crossplane provisioning)
**Effort:** ~3 hours combined (Terraform JSON dashboard resources).

Single-pane glance for the three highest-debug-volume areas. IRSA debug dashboard surfaces the #1 bug class instantly. Crossplane provisioning dashboard catches the silent-failure modes (XR with zero conditions) that defined phase 2.

Note: per the user direction in the next session, dashboards become more valuable once we have multiple workload clusters (phase 6). Build the **terraform JSON** for these but don't agonize over visual polish.

**Tier C total effort:** ~7-8 hours.

---

## Tier D — cruft removal that unlocks parallelism (do early; pays back next session)

These removals reduce maintenance surface AND enable other speedups. Cheap and immediate.

### D1. A6-014 — Delete `.github/scripts/post-comment.py` + `tests/unit/test_post_comment.sh` (A6-015)
**Effort:** ~30 minutes. Includes preserving rendering via A1→A6-013 fixtures.

Now that the agent runs `terraform` in-sandbox, plan/apply diffs go in the PR body directly. The auto-comment script is workflow-Actions-only legacy. Removes one whole bug-prone file plus its unit test. Per P→A6-001 "blast radius" rule, write the in-PR-body summary path first, then remove.

### D2. A6-007 — Replace `phase-2-diagnose.yml` with `scripts/diagnose/phase-2.sh`
**Effort:** ~1 hour. Includes A1→A6-001 (CloudTrail + Prom snapshot upgrade) and A4→A6-007 (preserve section headings for grep continuity).

The workflow was a dispatch-only state dumper because the agent couldn't reach kubectl. Now kubectl is 2 seconds away. Inline the bundle into a script + extend with CloudTrail capture. Removes ~250 lines of workflow YAML.

### D3. A6-008 — Delete `chainsaw-verify.yml` once chainsaw runs locally
**Effort:** ~30 minutes (with A6-009 follow-up).

The SHA-handshake verifier existed because chainsaw was workflow-only. With the sandbox, `bash tests/chainsaw/run.sh` is the test. Remove the dispatch-then-verify dance. Per A3→A6-002, add a lint that prevents the pattern from re-emerging.

### D4. A6-029 — Inline `aws-creds-check.sh` into a one-line preflight
**Effort:** ~15 minutes. Per A4→A6-029, keep a one-line `scripts/preflight.sh` that wraps STS + sandbox region whitelist + EC2 instance-type whitelist (guardrail value beats LoC value).

### D5. A6-022 + A6-023 — Move `terraform-validate.yml` + `unit-tests.yml` to pre-commit + pre-push hooks
**Effort:** ~1.5 hours combined. Per A3→A6-006, keep one minimum CI run that asserts both pass on main — local-only runs miss other contributors' breakage.

Both workflows were guardrails for an agent that couldn't run validate/unit-tests locally. Now they can. Saves ~30 seconds per push of CI wall-clock + reduces the noise of "the lint failed" notifications.

**Tier D total effort:** ~4 hours. **Net code-line reduction:** several hundred lines.

---

## What I would explicitly NOT build (and why)

These looked promising but I assess effort ≈ or > time saved over remaining project life:

### A5-016 — Adopt Terragrunt run-all
Cost: ~8-16 hours to migrate. Saves: ~5 min per `terraform apply` (the parallel apply itself, not the wait). Break-even: ~100+ applies. Not worth it for a project with ~6 distinct terraform roots and ~10-20 remaining sessions.

### A5-027 — Redis/SQLite event bus for subagent coordination
Cost: ~12+ hours. Saves: polling overhead in subagent orchestration. Premature optimization — the current agent runs one task at a time, and the event-bus value only materializes with sustained subagent pool work.

### A5-040 — Kind rehearsal cluster running parallel to EKS bring-up
Cost: ~8 hours. Saves: phase-2 composition iteration. **Already have chainsaw doing this.** Adding a second kind cluster is duplication unless we're doing phase 3 EKS-via-XRD, where EKS provisioning is ~15 min and a rehearsal might be worth it. Defer until phase 3 starts.

### A5-049 / A5-050 — Warm pool VPCs / terraform import
Cost: ~6 hours per. Risk: orphan AWS resources, state drift, sandbox-cap violations. Saves: ~5 min phase-0 wall-clock. The risk-adjusted ROI is negative; sandbox limits make warm pools fragile.

### A1-060 — Synthetic canary Lambda
Cost: ~4 hours. Saves: first-derivative health signal. Sandbox is ephemeral — canary value only materializes for a long-running production environment. Build at phase 6 if at all.

### A2-009 — Keycloak realm-lifecycle test
Cost: ~3 hours. Phase 5 only. Defer until phase 5 begins; building now means tracking spec changes for ~10 sessions before it matters.

### A1-063 / A1-064 — Keycloak token roundtrip + workload cluster probe
Same reasoning as A2-009. Phase 5/6 only. Defer.

### Most of A3 (static lints beyond B1/B2/B6/B8)
The A3 lints are great but most overlap. A6 cross-comments already note many are redundant (A3-014+A3-015+A3-049, A3-018+A3-019, A3-011+A3-060). Build a small set of high-value lints; don't author 30 micro-lints. The B-tier picks cover the highest-value distinct invariants.

### Most of A4 (debug dispatch workflows)
A6 cross-comments correctly note that A4-001, A4-002, A4-003, A4-018, A4-021, A4-041, A4-043, A4-047 are all "dispatch a kubectl/aws command via workflow" — obsolete now that the sandbox runs them directly. **Build the local-script equivalents (Tier A above) instead of the workflow forms.**

---

## Cross-cutting infrastructure to extract once

Per the clustering review's lesson — extract shared infra once, not per-spec:

| Shared piece | First introduced by | Used by |
|---|---|---|
| `# noqa: <lint-name> - <reason>` allowlist marker | B1 / B2 | All static lints |
| `tests/unit/_lib/hcl_extract.sh` HCL regex parser | B1 (terraform_data lint) | B1, B2, B6 |
| `scripts/_lib/aws-cli-helpers.sh` (whereami, region, account) | S4 (whereami) | S4, S5, A1, A4, all Tier C |
| `scripts/_lib/k8s-helpers.sh` (kubectl + auth + retry) | S7 (wait-for-claim) | S2, S7, A2, A3, A5 |
| `tests/regression/<bug-id>/` fixture layout | B4 (regression corpus) | Every bug fix going forward |
| `dashboards/*.json` Terraform-applied dashboards directory | C6 | C6 + all future dashboards |

---

## Recommended implementation order

If I were doing this work serially over the next few sessions, my preferred order:

**Session 1 (after the hook bug is fixed):**
1. S4 + S5 (whereami + phase-status) — 3 hours; immediately useful for every later session.
2. D1 + D4 (delete post-comment.py + inline aws-creds-check) — 1 hour cleanup.
3. C1 + C2 (CloudTrail + EKS control-plane logging) — 1 hour terraform.
4. Then resume Bug 3 (Crossplane provider bump) with these primitives in hand.

**Session 2:**
1. S1 (SPEC-A4 chainsaw catch hook) — 2 hours.
2. S2 (crossplane-trace.sh) — 3 hours; **transformative for all later phase 2/3 debugging**.
3. S3 (irsa_trust_validator.py --all) — 2 hours.

**Session 3:**
1. S6 (kubeconform pre-commit) — 1 hour.
2. S7 (wait-for-claim.sh) — 2 hours.
3. S8 (Logs Insights queries) — 1 hour.
4. S10 (apply-zero-resources runbook) — 30 min.
5. S9 (Composition render dry-run) — 2 hours.

**Session 4 (Tier A as background work):**
1. A1, A2, A3 (crossplane-version-report, eso-trace, kyverno-explain) — 5 hours.
2. A4, A5 (diff-state, krew wrapper) — 4 hours.

**Session 5+ (Tier B during phase 2b work):**
1. B1, B2, B6 (static lints) — 3.5 hours combined.
2. B3, B4 (IRSA invariant tests + regression corpus scaffold) — 3 hours.

**Tier C (auto-tagging + dashboards):** schedule when starting phase 3 work — the dashboards become more useful when there are workload clusters to observe.

**Tier D residual (A6-007, A6-008, A6-022, A6-023):** as opportunistic cleanup whenever touching the relevant files.

---

## Estimated cumulative ROI

Effort and savings are in the same currency (agent wall-clock + context cost).
The "hours saved" column counts both reactive debugging cycles avoided AND
the context-window thrashing of those cycles (worth ~1.5× the raw hours).

| After... | Hours invested | Hours saved per remaining session | Sessions remaining (estimate) | Net savings |
|---|---|---|---|---|
| Tier S complete | ~17 | ~2-3 | ~15-20 | 13-43 hours net |
| Tier S+A complete | ~29 | ~3-4 | ~15-20 | 16-51 hours net |
| Tier S+A+D complete | ~33 | ~3.5-4.5 | ~15-20 | 19-57 hours net |
| Tier S+A+B+D complete | ~43 | ~4-5 | ~15-20 | 17-57 hours net |
| All four tiers complete | ~51 | ~4.5-5.5 | ~15-20 | 17-59 hours net |

**The big diminishing-returns inflection is after Tier S+A+D.** Tier B and C
are still positive ROI but the marginal hour spent on them saves less than
the marginal hour spent on the first three tiers.

**Important caveat under apples-to-apples**: Tier B prevention items become
relatively more valuable because every prevented bug cycle is a full
debug-session avoided (not just the diagnosis minutes saved). I'd promote
B1 (manifest hash lint), B2 (IRSA SA pinned lint), and B6 (DeploymentRuntimeConfig
SA pinned lint) into Tier S+ alongside the primitives — they each cost
~1 hour to build and each prevent a multi-session bug class that has
already happened more than once.

**Revised recommendation: commit to Tiers S, A, D, plus B1+B2+B6 from B.**
Treat the rest of B and C as opportunistic — implement individual items
when adjacent work makes them cheap (e.g., add a regression test alongside
the bug fix that introduced it; add CloudTrail when you're already editing
base/).

---

## Open questions for the user

1. **Sequencing**: do you want the implementation order above, or do you weight phase-2-throughput (Bug 3 fix first, primitives second)? My preference is primitives first because Bug 3 work itself benefits from S1+S2+S3.

2. **Cluster ownership of dashboards (C6)**: should dashboards be applied per-phase or as a separate `terraform/observability/` root that's applied once?

3. **Regression corpus (B4)**: should this live in `tests/regression/` or be folded into `tests/integration/`? I'd argue separate dir for clarity but the maintenance pattern could differ.

4. **Cruft removal blast radius**: Tier D items remove load-bearing-for-CI workflows. Should I open one PR per removal (slow review, safe) or one bundled cleanup PR (fast, riskier)?
