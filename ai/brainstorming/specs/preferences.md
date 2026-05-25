# Implementing-agent preferences — which specs to build, in what order, and why

**Author:** implementing agent (Claude), at the end of the 2026-05-25 session
**Context:** the 15 specs under `ai/brainstorming/specs/SPEC-*.md` were
authored by parallel subagents. The orchestrator's `CLUSTERING-REVIEW.md`
groups them into six clusters with a recommended sequencing. This file
records **which specs I (the implementing agent) actually want built first
and why**, evaluated against (a) the specific pain of the 2026-05-25
Crossplane 2.3.0 upgrade session, and (b) recurring pain across recent
sessions in `retrospective/`.

The prioritization here is my preference as the agent who has to do the
work. It is not necessarily the user's priority — the user may weight
phase-2 throughput differently. Treat this as input, not a decision.

---

## TL;DR

| Tier | Specs | Why |
|---|---|---|
| **Tier 0 — build before resuming Bug 3** | **A4** | Makes the very next chainsaw iteration loop faster. ROI compounds across every future chainsaw run. |
| **Tier 1 — build next, in order** | **B3**, **B2**, **A1** | B3+B2 are 30-second static lints that catch real prior-session bugs. A1 unlocks A2 and the whole "structured claim diagnosis" branch. |
| **Tier 2 — high overall ROI** | **A2**, **C1+C5** (Cluster 3 combined PR), **A5** | A2 needs A1 first. C1+C5 close the "silent no-op apply" gap. A5 makes Terraform failures self-diagnostic. |
| **Tier 3 — solid coverage builds** | **B1**, **B5**, **B4**, **A3** | All address known bug classes but lower urgency right now. |
| **Tier 4 — defer** | **C2**, **C3**, **C4** | Higher review surface, more dependencies; defer until phase 2 is green and phase 3 is in flight. |

**My single strongest preference:** ship **A4 before any further Bug 3
iteration.** Bug 3 will dispatch chainsaw 3-5 times during the
provider-version bisect. Each iteration without A4 costs me ~5 minutes
of manual log parsing. With A4, each red iteration auto-dumps the
relevant events / describes / logs and I see the cause in seconds.

---

## Evaluation criteria

I scored each spec against five axes:

1. **Direct relevance to this session's pain** — would this spec have
   shortened the 2026-05-25 session?
2. **Direct relevance to the next session's known work** — would this
   spec speed up Bug 3 (provider version bump → chainsaw iterate)?
3. **Cross-session bug-class coverage** — does this spec catch a bug
   class with documented prior occurrences in `retrospective/`?
4. **Effort** — small (≤1 PR, ≤1 hour), medium (1 PR, 2-3 hours),
   large (multi-PR stack or >3 hours).
5. **Dependencies** — does this spec require another spec (or a
   baseline cleanup) to land first?

A spec scores high in my priority list when (1) or (2) is "yes",
effort is small/medium, and dependencies are few.

---

## Tier 0 — must-build before resuming Bug 3

### SPEC-A4 — shared chainsaw `catch:` hook for failure diagnostics

**Why this is the single highest-ROI spec for me right now.**

The 2026-05-25 session ran chainsaw against PRs of changing scope at least
five times. Each failure left me with a 245-second timeout and a generic
`asserts: failed` message — every other diagnostic step was manual:

1. SSH into the kind cluster's transient state (not possible — it was torn down)
2. Pull the GitHub Actions job log (170 KB)
3. Grep for the actual event / describe / log line that explained why
4. Cross-reference against the XR's `spec.resourceRefs`

Each manual cycle took 3-5 minutes. **A `catch:` hook that ran
`kubectl get events -A --sort-by=.lastTimestamp | tail -30`,
`kubectl describe xplatformsecret`, `kubectl -n crossplane-system logs deploy/... --tail 100`,
and `kubectl get externalsecret -A -o yaml` on every failure would have
surfaced each of the three bugs (SSA schema rejection, RBAC denial, slow
provider) in seconds — no manual grep.**

**Bug 3 iteration cost without A4:** 5 iterations × 5 min parse = 25 min
of dead time per session.
**Bug 3 iteration cost with A4:** 5 iterations × 30 sec scan = 2.5 min.

The asymmetry is so large that I would rather pay the 2-hour A4 build
cost than start Bug 3 without it.

Effort: medium (~2 hours). Dependencies: none. Independent.

---

## Tier 1 — build next, in order

### SPEC-B3 — `terraform_data` manifest hash lint

A 30-second static lint that statically checks every `terraform_data`
resource with an inline manifest has `sha256(local.<manifest>)` in its
`triggers_replace`. PR #67 had to be created specifically because PR #66
missed this — an entire PR's only purpose was to add a hash. That's the
exact bug class B3 prevents at authoring time.

Effort: small (~1 hour). Dependencies: none. Independent.

**Why I want it before A1:** it's the smallest possible win. One PR, one
test file, one fixture pair. Low review surface. High signal: every
future `terraform_data` resource the project ships gets caught at
author-time, no apply needed.

### SPEC-B2 — IRSA SA-pinned lint

The deepest bug from the prior session (the "Bug 5" cascade leading to
PRs #64-#68) was that `DeploymentRuntimeConfig` didn't pin the SA name,
so Crossplane derived a hash-suffixed name that didn't match the IRSA
trust subject. B2 statically checks: for every IRSA trust subject of the
form `system:serviceaccount:<ns>:<name>`, there exists a manifest in the
repo that pins exactly `<ns>:<name>` as the SA.

This is the same recurring bug class. Catching it as a static lint costs
30 seconds per run; missing it costs an entire phase-2 session.

Effort: small-medium (~1.5 hours). Dependencies: none.

### SPEC-A1 — claim chain walk on Ready=False

The big unlock. After A1 lands:
- A2 (decision tree) becomes implementable (it consumes A1's output).
- The crossplane-claim-verify skill goes from "wait, then say Ready or
  not" to "wait, then on failure walk the chain (claim → XR → MR →
  provider → SA → IRSA) and surface MATCH/MISMATCH at every link".
- B4's class-D classifier has a place to plug in.

Effort: medium (~3 hours). Dependencies: none directly, but cluster
review notes "PR-1.A1 is the single highest-leverage spec" — it unlocks
A2, A3 follow-up, B4 consumer, and C2's structural pattern.

**Why I want it in Tier 1, not Tier 0:** it's a bigger build, and Bug 3
can proceed without it (A4 covers most of the same ground for chainsaw
flows; A1's value is more for live-cluster flows where the user runs an
ad-hoc probe claim).

---

## Tier 2 — high overall ROI, build after Tier 1

### SPEC-A2 — decision tree naming the gap (depends on A1)

Once A1 surfaces the chain state, A2 classifies the failure into one of
four named classes (A: composition function, B: provider package, C:
RBAC/SA, D: drift). This is the moment "I'm stuck debugging" becomes
"this is a class B failure, the playbook is X."

Effort: medium (~2 hours). Dependencies: **A1 must land first**.

### SPEC-C1 + SPEC-C5 — Terraform drift detection (combined per Cluster 3)

Both run `terraform plan -detailed-exitcode`. C1 fires in CI immediately
after `apply-and-verify`. C5 fires as the final integration test. Both
catch the PR #67 silent no-op class at runtime (B3 catches the same at
author time; together they're defense in depth).

Effort: medium (~2 hours combined per cluster review). Dependencies:
land after Cluster 2 baseline cleanup so the lints don't churn the same
files.

**Why both, combined:** they share an allowlist, share the
`scripts/diagnose/tf-drift-check.sh` helper, share the output budget.
Shipping separately would duplicate three pieces of infrastructure.

### SPEC-A5 — terraform-ci-watch apply-failure intent-vs-reality diff

When the wrong `--enable-claim-ssa=false` flag caused a helm 5-minute
timeout, the immediate evidence was just "helm timed out". A5 would have
surfaced "intent: helm release upgraded with args=[...]; reality: pod
in CrashLoopBackOff; log: unknown flag --enable-claim-ssa".

Effort: medium (~2 hours). Dependencies: none.

---

## Tier 3 — solid coverage builds, lower urgency

### SPEC-B1 — shell safety lint

Catches the bash `$UID` shadowing + missing `set -e` class documented in
PR #59. Already partially implemented in two existing lints
(`test_shell_readonly_var_assignment.sh`,
`test_integration_scripts_strict_mode.sh`); B1 consolidates and extends.

Effort: small-medium (~2 hours including supersedes-existing-lints
cleanup). Dependencies: Cluster 2 baseline cleanup PR (PR-2.0).

### SPEC-B5 — account-ID hardcode lint

Enforces AGENTS.md §8.1 at author time. The handoff scrub a couple
sessions back was a 12-place find-and-replace; this lint prevents the
next recurrence.

Effort: small (~1 hour). Dependencies: Cluster 2 baseline cleanup
(needs `# noqa: account-id` allowlist for the legitimate references).

### SPEC-B4 — Kyverno SA-existence audit policy

Runtime version of B2 — same invariant, different lifecycle moment.
Catches IRSA-SA drift introduced by ArgoCD sync, manual hand-edits, or
chart updates. Pairs with A2's class D classifier.

Effort: medium (~2 hours). Dependencies: lands after A2 so A2 can read
the PolicyReports.

### SPEC-A3 — `phase-2-diagnose.yml` IRSA / SA / reconcile steps

Adds three diagnostic dumps to the existing workflow. Useful in CI-only
sessions where the agent can't invoke the skill directly. Partially
duplicated by A1 once it lands (same diagnostic content, different
invocation surface).

Effort: small (~1 hour). Dependencies: none. Anytime.

---

## Tier 4 — defer until phase 2 green + phase 3 in flight

### SPEC-C2 — claim-verify AWS shape assertion

High value (catches "claim Ready=True but AWS resource is wrong") but
introduces the per-XRD contract bundle idiom — that's a meaningful
authoring discipline addition. Better to land after the project has more
XRDs (phase 3 brings PlatformCluster + others).

Effort: large (~3 hours plus per-XRD backfill).

### SPEC-C3 — terraform resource tag check

Requires `default_tags` prerequisite PR before C3 itself can land.
Useful for cost attribution and reporting, but doesn't directly
accelerate any session's debug loop.

Effort: medium (~2 hours plus prerequisite PR).

### SPEC-C4 — chainsaw golden-file assertion

Highest coverage build of the lot, but requires backfilling every
existing chainsaw scenario with `expected/<resource>.yaml` golden files.
Defer until C2's contract bundle pattern is established (C4 extends the
same idiom).

Effort: large (~4 hours plus backfill).

---

## What I would NOT build under any priority scheme

None of the 15 are bad — every one addresses a documented bug class.
But I would not start any Tier 4 spec before the project has reached
phase 2 green on the live cluster. The Tier 4 specs are about
strengthening an already-working pipeline; the current pipeline isn't
working yet.

---

## How this prioritization differs from the orchestrator's clustering review

The clustering review optimizes for **review surface and merge order**.
My prioritization optimizes for **immediate ROI to the agent doing the
next implementation task**. The two are mostly aligned, but:

- The clustering review puts **PR-2.0 (baseline cleanup) first** because
  it unblocks Cluster 2. I put **A4 first** because it accelerates the
  Bug 3 iteration loop, which is the next concrete task. Cluster 2
  doesn't help me until I'm authoring new code that the lints would
  catch.
- The clustering review treats A1 + A2 + C2 as a coherent stack
  (Cluster 1). I break A1 out as Tier 1 standalone because A2 and C2
  have different urgency — A2 high (Tier 2), C2 deferred (Tier 4).
- I would skip the prerequisite PR for C3 entirely until C3 itself
  becomes urgent. The clustering review treats it as a sequencing step.

---

## My recommendation for the user

Build Tier 0 (A4) before resuming any Bug 3 work. Then either:

1. **Sequential path** (lower risk, slower wall-clock): land A4, then
   Bug 3, then loop back to Tier 1 (B3 → B2 → A1).
2. **Parallel path** (higher throughput): land A4, then start Bug 3
   on a branch while I implement B3 and B2 in parallel (both are
   small, mechanical, no risk of conflict with the Bug 3 branch).

I prefer **the parallel path** — A4 + Bug 3 in flight + B3/B2 as
background fill — because the wait windows during Bug 3 (chainsaw
dispatch, terraform apply) are exactly the windows where small static
lints can be authored without context-switching cost.

---

## Open questions for the user

1. Are you OK with me building A4 before continuing Bug 3?
2. Do you want each spec implementation as a standalone PR, or should I
   stack them per the clustering review's recommended shape?
3. Is the prioritization above aligned with your sense of the project's
   needs, or do you weight phase-2 throughput more heavily than I am?
