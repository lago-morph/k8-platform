# AGENTS.md suggestions — 2026-05-24-62

These are proposed additions to the project's agents file (`AGENTS.md` at the repo root). Each section contains:

1. **Proposed addition** — exact text to paste.
2. **Why this earns its place in your agents file** — the argument, grounded in this session.

Decide each on its own merits. Skip ones that don't apply; copy-paste the ones that do.

---

## Suggestion 1: Verify evidence, not exit codes

### Proposed addition

> **§6.X — Verify by evidence, not by wrapper exit code.** For any action whose granularity is finer than its outer success indicator (workflow_dispatch, PR merge, kubectl apply, ArgoCD sync, AWS describe), the agent MUST quote a verbatim line of the underlying evidence — a log line, a status condition, an API response field — before reporting the action as "done", "verified", or "successful". Wrapper success is necessary but NOT sufficient. Scripts can pass-on-fail; workflow steps can succeed while the assertion they wrap fails; PR merges can stall mid-merge. If the evidence quote is not in the response, the verification has not happened.
>
> *Grounded in: integration-tests run 26347839740 reported `conclusion: success` while four wait_for calls timed out and the K8s Secret never materialized. The agent reported "Phase 2a is genuinely verified"; it was not.*

### Why this earns its place in your agents file

The session lost ~45 minutes and significant user trust on a single instance of this failure mode. The agent read `conclusion: success` from a workflow_dispatch and reported phase-2 verified; the user pushed back, the agent re-read the log, and found the script lying due to a missing `set -e` and a `$UID` shadow bug. That bug had been present in the codebase the entire prior session, never caught. The rule's cost is one extra grep + one extra quote per outcome claim — measured in seconds. The rule's value is the catch rate on every silent-PASS bug class, of which we know at least the bash-script flavour exists in the codebase right now.

---

## Suggestion 2: PR state IS the merge signal

### Proposed addition

> **§3.X — PR draft/ready state is load-bearing UI.** When the agent opens a PR, the `draft` flag MUST reflect the agent's actual signal to the user:
> - `draft: true` when CI is red/yellow, when the agent is still iterating, or when there's an explicit hold instruction
> - `draft: false` (ready for review) when CI is green AND the agent wants the user to merge
>
> When CI greens on a draft PR with intent-to-merge, the agent MUST promote it via `update_pull_request method=update draft: false` and tell the user. When listing open PRs in status updates, the agent MUST name each PR's draft/ready state explicitly.
>
> *Grounded in: this session opened 10 PRs as draft regardless of state; the user explicitly corrected this mid-session ("leave PRs you are still working on in draft, and ones you want me to merge as ready"). The very next PR (#61) was opened ready, CI green, and merged smoothly.*

### Why this earns its place in your agents file

The user has limited bandwidth to triage PRs. If every PR is draft, they have to ask the agent each time which to merge. That's friction proportional to PR count — and this session shipped 11. The fix is zero-cost on the agent's side (set one flag correctly) and removes the user-side ambiguity entirely.

---

## Suggestion 3: Verify-then-PR

### Proposed addition

> **§6.X — Verify-then-PR.** For any PR whose value depends on a manual check (chainsaw, integration-tests, phase-2-diagnose, custom diag workflow), the agent SHOULD push the branch, dispatch the relevant check against the SHA, wait for the check to go green, and ONLY THEN open the PR. Per AGENTS §6.7's chainsaw rule, generalized to all manual checks.
>
> Exception: workflow-only PRs where the workflow itself is the check (chicken-and-egg). Document the exception in the PR body.
>
> *Grounded in: every PR opened "to dispatch chainsaw against the SHA" then waited for chainsaw to finish before being merged-ready. The session opened PRs before checks completed, leaving red verify badges visible to the user.*

### Why this earns its place in your agents file

Opening a PR before its check completes leaves a visible red badge that the user has to mentally filter. The cost of the rule is ~5–15 minutes of wall-clock waiting per PR; the value is a PR that's actually green when reviewed. Repeated 11 times this session, the cost of not-having-the-rule was 11 confusing PRs.

---

## Suggestion 4: Diagnose-first-then-mutate

### Proposed addition

> **§6.X — Diagnose before any mutating op >5 minutes.** Before dispatching any cluster-mutating workflow whose runtime exceeds 5 minutes (apply-and-verify, teardown-rebuild, EKS provisioning), the agent MUST dispatch a read-only diagnostic first to verify the pre-state. The diagnose's evidence MUST be quoted in the announcement of the mutating dispatch.
>
> *Grounded in: phase=management apply-and-verify dispatched against an unfixed phase-2 state; 15 min of CI wasted before the policy-09 admission failure surfaced. A 2-min diagnose would have caught it.*

### Why this earns its place in your agents file

Mutating operations on the live cluster cost: real $$, real time, occasional cleanup work, and agent context. The cheapest precaution — a read-only diagnose — is at least 5× faster than the operation it gates and catches the majority of preventable failures. This session has the bug-of-record.

---

## Suggestion 5: bash `$UID` and other readonly built-ins

### Proposed addition

> **§6.X — No assignment to bash readonly built-in variables.** Never write `UID=…`, `EUID=…`, `BASHPID=…`, `RANDOM=…`, `LINENO=…`, `SECONDS=…` in any bash script committed to this repo. Under `set -u` the assignment silently fails and the variable retains its built-in value (usually the runtime's process UID), which downstream code uses with confusing consequences. Defended by `tests/unit/test_shell_readonly_var_assignment.sh`.
>
> *Grounded in: tests/integration/11_platform_secret_e2e.sh used `UID=$(kubectl get xplatformsecret …)`. The assignment was rejected silently; `$UID` retained the runner's 1001; `ASM_KEY=k8-platform/1001` collided across runs; every ASM put failed with `ResourceNotFoundException`.*

### Why this earns its place in your agents file

The bug class is invisible without the lint — `set -u` doesn't abort, and `set -e` doesn't either. The lint costs ~30s to author and runs in milliseconds. The bug it prevented took two hours of session time to root-cause and was hidden behind a silent-PASS for a session and a half.

---

## Suggestion 6: chainsaw `script:` blocks are POSIX sh

### Proposed addition

> **§6.X — Chainsaw `script:` blocks run in POSIX sh (dash on Ubuntu 24.04).** Inside a chainsaw `script:` block, use only POSIX-compatible code: `set -eu` (NOT `set -euo pipefail`), `[ ... ]` (NOT `[[ ... ]]`), no bash arrays, no process substitution. For pipefail semantics, restructure to avoid pipes or move the logic into `tests/chainsaw/run.sh` which runs in bash.
>
> *Grounded in: chainsaw run 26346566417 failed with `sh: 1: set: Illegal option -o pipefail` despite three earlier-in-session uses of the same pattern not having tripped (the failures upstream of the script step masked it).*

### Why this earns its place in your agents file

The cost of the rule is one mental check per chainsaw scenario authored. The cost of not having it is what we saw: pattern propagated across the codebase via copy-paste and surfaced only when an upstream change exposed the script: step. Future agents authoring chainsaw scenarios are statistically likely to default to `set -euo pipefail` (the bash convention this codebase uses elsewhere); the rule prevents the propagation.

---

## Suggestion 7: Crossplane `status.conditions` order is non-deterministic

### Proposed addition

> **§6.X — Do not use positional asserts on Crossplane `status.conditions[]`.** Crossplane controllers (XRD, XR, Composition, Function reconcilers) emit `status.conditions` in non-deterministic order. Chainsaw positional `assert:` blocks on these will fail randomly. Use `kubectl wait --for=condition=<Type>` inside a `script:` block instead — order-agnostic. The same applies to ESO ExternalSecrets and Kyverno ClusterPolicies (verified empirically per this session's chainsaw runs).
>
> *Grounded in: chainsaw run 26346566417 saw XRD conditions in [Offered, Established] order; run 26346745818 saw [Established, Offered] on identical code. Each run had a 50/50 chance of hitting the wrong ordering.*

### Why this earns its place in your agents file

This is a Crossplane behaviour, not a bug you can fix in the code under test. The rule's cost is one POSIX-sh script block per condition assertion. The cost of not having it is what we saw: a known-flaky test that retried until it happened to hit the right order, masking other failures.

---

## Suggestion 8: TDD lint before every bug fix

### Proposed addition

> **§6.X — TDD lint before every bug fix.** Every bug-of-record fixed in this codebase MUST ship with a unit-test lint at `tests/unit/test_<bug-class>.sh` that demonstrably goes RED on the unfixed code and GREEN after the fix. The lint scans all relevant files (not just the one where the bug was first observed), is wired into `tests/unit/run.sh`, and includes a comment citing the bug-of-record (run ID, error message).
>
> *Grounded in: PRs #59 and #61 demonstrated this. PR #59's UID-shadow lint caught the bug in both 11_platform_secret_e2e.sh AND scripts/diag-component.sh (the second one would have been missed without the scan-all-files property). PR #61's string-transform-type lint caught 9 instances I didn't initially notice.*

### Why this earns its place in your agents file

Without this rule, the same bug recurs the next time a similar pattern is authored. With this rule, the bug becomes a permanently-defended invariant. The cost is ~5 minutes per bug fix. The value is permanent regression prevention.

---

## Suggestion 9: Workflow_dispatch requires the workflow file on the default branch

### Proposed addition

> **§6.X — `workflow_dispatch` requires the workflow file to exist on the default branch.** GitHub will accept `workflow_dispatch` against non-default refs ONLY if the workflow's `.yml` is already on the default branch. Dispatching from a feature branch where the workflow was newly authored returns HTTP 404 / `Not Found`. To bootstrap a new dispatch workflow, open a small workflow-only PR and merge it first; THEN dispatch from feature branches.
>
> *Grounded in: PR #60's `phase-2-diagnose.yml` couldn't be dispatched from its feature branch until merged — surfaced as a confusing chicken-and-egg moment mid-session.*

### Why this earns its place in your agents file

The first time an agent hits this it spends 5–10 minutes debugging "why is dispatch returning Not Found?" The rule prevents that loop for every future first-time dispatch.

---

## Suggestion 10: Don't trust PR history; grep and verify

### Proposed addition

> **§6.X — Don't trust PR-history claims; grep and verify.** When the agent (or a doc) asserts "PR #N adds field X" or "the config includes Y per PR #N", the agent MUST grep the live source to confirm before relying on it. PRs can be reverted, merged-then-edited, or simply mis-described in retrospect.
>
> *Grounded in: the handoff doc's Step 11 said "Confirm the AppProject allows PlatformCluster claims (already does per PR #42's project spec)" — replacing trust-the-PR with `grep -A4 namespaceResourceWhitelist argocd/projects/*.yaml` was a finding in iteration 3 of the handoff review.*

### Why this earns its place in your agents file

The rule is a 5-second grep. The cost of not having it is a category of confidently-wrong actions based on stale PR history.

---

## Suggestion 11: AWS account change is a §6.6 stop condition

### Proposed addition

> **§6.6 (extension) — AWS account change is a hard stop condition.** Even under throughput-without-attention mode, a change of AWS account (or its credentials) halts the agent. The agent MUST re-confirm scope, secrets rotation, and Route53 hosted-zone presence with the user before resuming any dispatch.
>
> *Grounded in: AWS account `309191981509` torn down mid-session; the agent's behaviour in that moment was ambiguous between "ask first" (correct) and "throughput mode says press on" (would be catastrophic if the new account's secrets weren't rotated).*

### Why this earns its place in your agents file

Throughput mode is grant-once. An account change can invalidate everything the prior grant assumed (state backends, IRSA scope, Route53 zone, IAM policies, even cluster name semantics). The rule is fail-safe — when in doubt, ask. The cost is one extra confirmation per account change (rare). The cost of not having it is potentially destructive dispatches against an account the agent doesn't fully understand.

---

## Suggestion 12: Read every step's log, not the wrapper's

### Proposed addition

> **§6.X — When a workflow has multiple steps, read the LOG of the step you care about, not the workflow's overall conclusion.** GitHub's "workflow succeeded" badge means "every required step exited 0", which includes steps with `continue-on-error: true`. To know whether step N actually achieved its intent, read step N's log directly via the `list_jobs_for_workflow_run` → `download_job_logs` pair.
>
> *Grounded in: `tests/unit/test_helm_render.sh` is set `continue-on-error: true` in unit-tests.yml; every CI run claims "success" even though 4 assertions fail every time. An agent reading the badge alone would never know.*

### Why this earns its place in your agents file

The rule applies whether or not the project uses `continue-on-error`. The cost is one extra MCP call per verification (~2s). The value is no false-confidence reports.

---

## Suggestion 13: Iterative review for load-bearing docs

### Proposed addition

> **§6.X — Long-form load-bearing docs (handoffs, RFCs, plans, specs) get at least 3 review iterations.** Each iteration uses a subagent (named scope, named previous-iteration findings to verify) PLUS the agent's own re-read. Iteration N's prompt explicitly lists iteration N-1's findings for verification, so regressions are caught. Stop when two consecutive iterations surface no MEDIUM+ findings.
>
> *Grounded in: the handoff rewrite (PR #62) went through 3 iterations. Iteration 1 found 12 issues; iteration 2 found 11 new ones AFTER iteration 1's fixes were applied; iteration 3 found 6 more. A single-pass review would have shipped 22 known-now-fixable issues.*

### Why this earns its place in your agents file

Long docs are the most expensive to get wrong — they're read by future agents who can't ask for clarification. The rule's cost is ~3× one pass, which is small relative to a doc's lifetime. The rule's value is the cross-iteration regression detection that no single pass provides.

---

## Suggestion 14: Subagent prompt brief template

### Proposed addition

> **§6.X — Subagent prompts MUST include: (a) the exact file path or context source, (b) the data schema (YAML, JSON, etc.), (c) specific questions to answer (not "summarise"), (d) output format and word cap, (e) verbatim-quote-required-for-evidence directive.** A subagent with vague questions returns vague summaries; a subagent with specific questions returns specific evidence. The verbatim-quote directive prevents paraphrase drift.
>
> *Grounded in: phase-2-diagnose log was 155K chars. The subagent prompt that worked had file path + jentic schema + three specific questions + 1500-word cap + "quote verbatim" directive. Returned both root-causes in one call.*

### Why this earns its place in your agents file

Most subagent prompts in this codebase already follow this; codifying the rule prevents drift. The cost is ~30 extra seconds per subagent dispatch (writing the structured prompt). The value is the difference between a useful return and a useless return — measured in entire subagent dispatches saved.

---

## Suggestion 15: Cluster resource sync expects ArgoCD's 3-min refresh

### Proposed addition

> **§6.X — After triggering ArgoCD-managed state (e.g., a Terraform apply that runs `terraform_data.argocd_bootstrap`), wait at least 3 minutes before asserting the resources are present.** ArgoCD's default refresh interval is 3 min; sync-wave cascades are serial. "Just dispatched, immediately polling" creates a race condition that surfaces as `OutOfSync` from timing, not from real drift.
>
> *Grounded in: handoff iteration 1 review surfaced "Step 3 says wait ~30 seconds, that's way too short."*

### Why this earns its place in your agents file

A short wait causes false-positive diagnostics that lead to chasing non-bugs. The rule's cost is 2.5 extra minutes per dispatch. The cost of not having it is hours debugging ghosts.
