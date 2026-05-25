# Cross-review additions from the primary (orchestrator) agent

Pass after all six brainstorming subagents and their pairwise cross-reviews
completed. The primary's lens: cross-cutting patterns, sequencing across
the six tracks, meta-tooling that pays dividends across all of them.
Additive only. Nothing critical.

## For A1-debug-tools-max-capability.md

| ID | Idea | Category | Justification | Applies to phase |
|---|---|---|---|---|
| P→A1-001 | A single `inspect <resource>` shell wrapper that auto-dispatches (claim → XR → MR → IRSA → cloud) based on `kind` so the agent types one verb regardless of what's broken. | shell-helper | Eliminates the "which command do I run for this kind?" cognitive tax that recurs every debug loop. | 1+ |
| P→A1-002 | A `make doctor` target that runs every cheap read-only health probe (caller-id, kubeconfig age, ArgoCD reachable, CRDs present, provider Healthy, IRSA SA-name pinned) and emits a one-screen status board. | runbook | Cheap pre-flight that catches "stale kubeconfig" / "rotated account" before they cost a debug loop. | 0+ |
| P→A1-003 | Auto-create a CloudWatch Logs log group `/k8-platform/agent-session/$DATE` and tee every `aws`/`kubectl` invocation into it for postmortem replay. | cloudwatch-setup | Makes "what did the agent actually do?" answerable after the sandbox is torn down. | 0+ |
| P→A1-004 | A `dashboards/` folder of one JSON per dashboard (EKS, Crossplane, ESO, ArgoCD, ExternalDNS, Kyverno, Cognito) that Terraform applies idempotently on every phase-1 apply. | dashboard | Re-bootstrappable across account rotations; zero clicks to get to "what's going on right now". | 1+ |
| P→A1-005 | A "diagnose digest" Python script that pulls the last hour from all relevant log groups + last 50 events from all crossplane-system pods + all MR statuses into a single ~5 KB digest the agent can paste back into context. | python-helper | Shrinks 170 KB diagnose logs into agent-readable evidence; closes the "context overflow" failure mode from the old diagnose workflows. | 1+ |
| P→A1-006 | Annotate every Terraform-managed resource with `tags = { k8platform-phase = "0"|"1"|"2", k8platform-component = "..." }` so CloudWatch / cost / drift queries can filter by phase. | terraform-postcheck | Lets dashboards/alarms scope to the phase being worked on without recomputing arn lists. | 0+ |
| P→A1-007 | A `wait-for` polyglot CLI (`wait-for claim/X ready`, `wait-for mr/Y synced`, `wait-for argo-app/Z healthy`, `wait-for irsa/<role> assumable`) — one tool, many backends. | wait-loop-helper | Replaces ad-hoc `until` loops scattered across runbooks. | 1+ |

## For A2-integration-e2e-tests-max-capability.md

| ID | Idea | Category | Justification | Applies to phase |
|---|---|---|---|---|
| P→A2-001 | A "test pyramid health" report that emits coverage-by-phase × layer (unit/kyverno/integration/chainsaw/e2e) and flags layers that haven't been touched in 30 days. | meta-test | Catches "we stopped writing chainsaw tests halfway through phase 2" before it becomes a habit. | 2+ |
| P→A2-002 | A property-based test harness that generates random valid PlatformSecret claim specs and asserts the round-trip invariant (claim accepted ⇒ ASM secret exists with matching tags). | property-test | Surfaces edge cases (long names, unicode descriptions, weird refresh intervals) that example-based tests miss. | 2+ |
| P→A2-003 | A "bug regression corpus" directory: every retro'd bug gets a one-file reproducer kept forever; CI runs the whole corpus on every PR. | regression-corpus | Turns institutional memory of past bugs into permanent guardrails. | 0+ |
| P→A2-004 | A cross-phase soak test that holds phase-2 claims live for 24 hours and asserts no MR flapping, no IRSA token expiry, no ArgoCD drift events. | soak-test | Catches slow-burn issues (token-lifetime mismatches, refresh-interval bugs) invisible to short tests. | 2+ |
| P→A2-005 | A "tear-down completeness" test that deletes a phase-2 claim and asserts every cloud resource it created is actually gone (ASM secret, IAM bindings, tags). | e2e-test | Defends against "ghost resources" that quietly accumulate cost. | 2+ |
| P→A2-006 | A negative-IRSA test that intentionally swaps the SA name on a deployment and asserts the provider goes Unhealthy within N seconds (regression for PR #66/#68). | irsa-test | Locks the SA-pinning fix permanently. | 1+ |
| P→A2-007 | A "manifest hash drift" test that mutates the body of a manifest controlled by `terraform_data.triggers_replace` without bumping the trigger and asserts the diff is detected (regression for PR #67). | unit-test | Prevents reintroduction of "edited the manifest but apply was a no-op". | 1+ |

## For A3-test-gaps-prior-constraints.md

| ID | Idea | Category | Justification | Applies to phase |
|---|---|---|---|---|
| P→A3-001 | A unit test that lints every shell script in the repo for `set -euo pipefail` + no readonly built-in assignment (`UID=`, `PWD=`, etc.) — the silent-PASS class. | unit-test | Catches the bug class behind PRs #46, #59 once and forever. | 0+ |
| P→A3-002 | A test that greps every workflow YAML for `continue-on-error: true` and requires a justification comment on the same line, or fails. | unit-test | Prevents "passed because the step was allowed to fail" — a recurring evidence-trust bug. | 0+ |
| P→A3-003 | A `tests/unit/test_no_account_id_hardcoded.sh` that fails on any 12-digit AWS account ID in `ai/`, `terraform/`, `crossplane/`, `argocd/`, `scripts/` (per AGENTS.md §8.1). | unit-test | Makes the §8.1 rule enforceable rather than aspirational. | 0+ |
| P→A3-004 | A Kyverno audit policy asserting every ServiceAccount referenced by an IRSA role's trust policy actually exists in the cluster (cross-resource consistency). | kyverno-policy | Catches the SA-name-drift class at runtime, not just apply-time. | 1+ |
| P→A3-005 | A chainsaw scenario per XRD that boots a kind cluster with crossplane + a mocked AWS provider and exercises the composition; runs in <2 min on every PR. | chainsaw | Provides "did the composition actually render?" coverage without touching real AWS. | 2+ |

## For A4-debug-tool-gaps-prior-constraints.md

| ID | Idea | Category | Justification | Applies to phase |
|---|---|---|---|---|
| P→A4-001 | A `scripts/diagnose/snapshot.sh` that emits a tarball capturing every relevant cluster + AWS read-only state at a moment in time, named by SHA — agent can paste a download link or untar locally. | diagnose-script | Replaces 6 different one-off diagnose workflows with one durable artifact. | 1+ |
| P→A4-002 | A retro template field "what command did we wish existed?" — every retro author lists 1-3 commands; once a quarter we promote the top votes into `scripts/`. | runbook | Turns retro signal into actual tooling without requiring a separate brainstorming session. | 0+ |
| P→A4-003 | A `scripts/diagnose/why-not-ready.sh <resource>` that walks status conditions of the resource and every dependency until it finds the leaf cause, prints a one-paragraph English summary. | diagnose-script | Collapses 30-minute "trace through resourceRefs" loops into one command. | 1+ |
| P→A4-004 | Pre-canned CloudWatch Logs Insights queries committed under `scripts/insights/` (one .json per common question — "IRSA AssumeRole failures last hour", "Crossplane reconcile errors for resource X"). | logs-insights-query | Removes the "what was that query syntax again" tax every debug loop. | 1+ |

## For A5-orchestration-post-actions.md

| ID | Idea | Category | Justification | Applies to phase |
|---|---|---|---|---|
| P→A5-001 | A `scripts/orchestrate/phase-graph.json` that declares phase × component DAG; a `phase-up.py` reads it and runs everything that can run in parallel at each frontier, with a Gantt-style progress dashboard. | dependency-graph | Codifies parallelism so future agents don't have to rediscover it. | 0+ |
| P→A5-002 | A "warm pool" subagent that, while phase-1 EKS is creating (15 min), pre-pulls every Helm chart, pre-renders every manifest, pre-validates every IAM policy doc, and pre-warms ECR images — net zero wall-clock cost. | parallel-apply | Captures the explicit "parallel unrelated work" insight from the user's prompt. | 1+ |
| P→A5-003 | Use the existing two-AZ constraint to deliberately structure modules so AZ-A and AZ-B resources can be applied as two parallel `terraform apply -target=` invocations. | parallel-apply | Same wall-clock budget gets twice the work done; safe within sandbox caps. | 1+ |
| P→A5-004 | A "bring-up race report" that records, per phase, which step was on the critical path; PR description auto-includes it so the next session knows where to attack next. | orchestration | Continuous improvement loop on cold-start time. | 1+ |
| P→A5-005 | Run the brainstorming-style fan-out pattern itself (this very session) as a reusable harness: `scripts/orchestrate/fanout.py <brief> <N>` spawns N subagents on a shared workspace. | subagent-pool | Generalizes what worked here so future brainstorms / reviews / audits are one command. | 0+ |

## For A6-removal-refactor.md

| ID | Idea | Category | Justification | Applies to phase |
|---|---|---|---|---|
| P→A6-001 | Mark every removal candidate with a "blast radius" tag (workflow / skill / script / doc) and require the replacement be merged first, then the removal — never the reverse. | refactor | Avoids the "we deleted the workaround before the replacement was proven" failure mode. | 0+ |
| P→A6-002 | Keep an `ARCHITECTURE-CHANGES.md` ledger of every workaround-removed with a one-line "was for X, replaced by Y, removed in PR #Z"; durable institutional memory. | dedupe | Future sessions don't reintroduce the workaround thinking it's new. | 0+ |
| P→A6-003 | The `phase-2-diagnose.yml` workflow can stay but be repointed: instead of running diagnose logic inline, it just invokes `scripts/diagnose/snapshot.sh` (which agents can also run locally) — single source of truth. | consolidate-script | Cuts duplication; keeps the dispatch entry-point for users who don't have kubectl handy. | 2+ |
| P→A6-004 | The `terraform-ci-watch` skill's capability-profile branching (`gh` / GitHub MCP / ext-github) collapses to one path now; trim the skill to that path only and keep a `legacy/` note for archaeology. | simplify | Removes the largest source of conditional complexity in the skill ecosystem. | 0+ |
| P→A6-005 | Replace bespoke `aws-creds-check.sh` / `k8s-logs.sh` / `route53-records.sh` thin wrappers with one-line snippets in `docs/runbook.md` — the wrappers added a layer without value. | removal | Less to maintain, more discoverable in the runbook. | 0+ |

## Meta — should also exist as artifacts

| ID | Idea | Category | Justification | Applies to phase |
|---|---|---|---|---|
| P-META-001 | A `ai/brainstorming/INDEX.md` that lists every idea ID with status (`new` / `in-progress` / `done` / `deferred` / `wontfix`); the source of truth for "what got picked up". | meta | The brainstorm only pays dividends if ideas can be tracked across sessions. | 0+ |
| P-META-002 | A "top 20" extraction pass after this brainstorm — single doc with the highest-leverage ideas chosen across all six files, ready to drop into the next session's handoff. | meta | Turns 800+ ideas into an actionable shortlist without losing the long tail. | 0+ |
| P-META-003 | Re-run this six-agent fan-out quarterly; diff the output to spot ideas that recur (high-signal) vs. those that fade (already addressed). | meta | Brainstorming as a longitudinal signal, not a one-shot. | 0+ |
