# Cross-review additions from A4

Lens: debug-tool gaps under prior constraints — retro-pain memory of how many cycles each
diagnose step cost without bridges. All additive: extensions, paired runbooks, loop-shorteners.

## For A1-debug-tools-max-capability.md

| ID | Idea | Category | Justification | Applies to phase |
|---|---|---|---|---|
| A4→A1-001 | Add a `scripts/whereami.sh --json` mode so a subagent can `jq` the output instead of re-parsing prose. | debug-assist | The retro pain was always "parse my own helper's output"; emitting JSON closes that loop. | 0+ |
| A4→A1-002 | Pair `phase-status.sh` with `phase-status.md` runbook that names which probe distinguishes `code-only` from `applied` for each phase. | runbook | Live probes are only useful if the operator knows what failing-probe means; runbook collapses interpretation. | 0+ |
| A4→A1-003 | Have EKS control-plane logging include a `scripts/eks-logs-tail.sh` thin wrapper that pre-selects the audit log group + last 5 min — surfaces what A1-003 enables. | runbook | Enabling logs without a paired reader leaves them undiscovered. | 1+ |
| A4→A1-004 | Add a `scripts/vpc-flow-grep.sh <src> <dst>` helper that compiles the most common SG-deny query into one command. | runbook | Flow logs alone burned hours in prior sessions because nobody remembered the schema. | 0+ |
| A4→A1-005 | Pair CloudTrail enablement with `runbook-cloudtrail-iam-debug.md` listing the five canonical Insights queries (AssumeRole denies, GetSecretValue denies, eks:* failures, sts:* failures, kms:* failures). | runbook | The data is only useful if the query is memorized. | 0+ |
| A4→A1-006 | Add an `irsa-failure-quick-quote.sh` that runs the A1-006 Logs Insights query and emits a single verbatim quote line per failure — feeds the verify-evidence-not-exit-codes skill. | shell-helper | Evidence-quoting cannot be skipped if the tool emits the quote ready-to-paste. | 1+ |
| A4→A1-007 | Add a `tee` mode to the audit-deny query that mirrors live results to `/tmp/last-audit-denies.json` for cross-session memory. | shell-helper | "Was this happening yesterday?" answerable across sessions. | 1+ |
| A4→A1-014 | Pair the dashboard with `runbook-dashboard-read.md` that names which panel rules out which bug class — turns glance into decision. | runbook | Dashboards without a decision tree are just wallpaper. | 1+ |
| A4→A1-018 | Add an `irsa_trust_validator.py --all` mode that iterates every role and prints a single table — turn one-shot validator into a fleet sweep. | python-helper | Bug 5 manifested across multiple roles; per-role invocation misses the pattern. | 1+ |
| A4→A1-019 | Have `crossplane-trace.sh` accept `--watch` to re-print the chain every 10 s — close the "is it making progress" loop. | runbook | Sessions burned re-running the trace manually every minute. | 2+ |
| A4→A1-028 | Add `eso-trace.sh --decode-token` to also dump the projected SA token claims of the ESO pod — folds A1-047 in for one-call ESO debug. | runbook | ESO + IRSA are the same bug 80% of the time; one call instead of two. | 1+ |
| A4→A1-032 | Add `nlb-trace.sh --record` to capture a baseline trace artifact per phase so future runs can diff. | runbook | "Worked yesterday" answerable in one diff. | 1+ |
| A4→A1-048 | Pair `diag-bundle.sh` with `diag-bundle-explain.py` that reads a bundle and prints a triage paragraph (Conditions=False rows + first-failing event). | shell-helper | Bundles are useless if the operator has to page through them. | 1+ |
| A4→A1-069 | Make `diag.sh` accept `diag.sh suggest` mode that prints the most likely specialist to invoke based on a one-line symptom. | debug-assist | Operator doesn't always know which subcommand to pick — guided entry shortens loops. | 1+ |
| A4→A1-070 | Add `cleanup-orphans.sh --dry-run --json` plus a CI check that asserts orphan-count==0 so leakage gets caught in PRs, not at session start. | runbook | Orphan detection is most useful as a guardrail, not a manual sweep. | 0+ |

## For A2-integration-e2e-tests-max-capability.md

| ID | Idea | Category | Justification | Applies to phase |
|---|---|---|---|---|
| A4→A2-001 | Pair the round-trip test with a `runbook-claim-roundtrip-debug.md` covering the four likely-failure points (Composition render, MR provisioning, AWS API, tag/KMS drift). | runbook | Test failures need a debug map ready, not authored mid-incident. | 2+ |
| A4→A2-003 | Capture the `simulate-principal-policy` output as a per-PR artifact so diffs across PRs surface drift trends. | shell-helper | Per-run only catches absolutes; diff-over-time catches creep. | 1+ |
| A4→A2-005 | Add a companion live-probe workflow `compare-irsa-trust-to-cluster.yml` that runs the invariant on demand from the sandbox between PRs. | dispatch-workflow | The test catches at PR time; the workflow catches drift between PRs. | 1+ |
| A4→A2-009 | Save the temp-realm test's auth-flow HAR/curl trace as an artifact for replay — debug speed-up for AuthN regressions. | shell-helper | OIDC failures are easier to replay than recreate. | 5+ |
| A4→A2-012 | Have the CloudWatch oracle output the exact Insights query URL so an operator can deep-link from a test failure. | shell-helper | Test failures should hand you the next click. | 2+ |
| A4→A2-016 | Pair the concurrency test with `runbook-claim-fanout-debug.md` listing the three known throttling signatures (ASM rate limit, IAM Create rate, EKS API 429). | runbook | When 20-claim fan-out goes red, knowing the throttle source saves hours. | 2+ |
| A4→A2-018 | Add a `soak-summary.py` post-processor that prints first-failure timestamp + suspected cause class — turns 60-min trace into one paragraph. | shell-helper | Soak data is voluminous; the summary is the actionable part. | 2+ |
| A4→A2-022 | After the chaos test, auto-emit a CloudWatch annotation marking the kill window so future Insights queries can correlate. | shell-helper | Correlation between chaos and observed behavior is currently manual. | 2+ |
| A4→A2-025 | Pair the OIDC-revoke chaos test with `runbook-oidc-revoke-recovery.md` documenting the exact `aws iam create-open-id-connect-provider` re-bind steps. | runbook | Chaos is only safe with a documented recovery path. | 1+ |
| A4→A2-034 | Have the full chain test emit a `chain-trace.json` artifact (timestamps per hop) so latency creep per hop becomes graphable. | shell-helper | Six-stage chain hides which hop is slowing. | 2+ |
| A4→A2-046 | Pair the teardown invariant test with `runbook-orphan-resource-sweep.md` listing the 7 known orphan classes (ENI, EBS, SG, OIDC provider, NodeGroup remnants, EKS log group, IAM role). | runbook | Enumeration is the only way to be sure. | 3+ |
| A4→A2-053 | Add a `rotation-latency-histogram.py` post-processor — track p50/p95 rotation time over sessions. | shell-helper | Rotation correctness is binary; latency creep is the silent killer. | 2+ |
| A4→A2-058 | Pair Bug-4 negative test with a `pre-commit-composition-render.sh` that runs `crossplane render` on every changed Composition before commit — same defense, shorter loop. | shell-helper | Catching at commit time is faster than catching in chainsaw. | 2+ |
| A4→A2-064 | Emit the per-phase teardown evidence as a verifiable quote bundle (per verify-evidence-not-exit-codes) so the PR body links to literal proofs. | shell-helper | Invariant-1 is load-bearing; evidence must be auditable. | 2+ |

## For A3-test-gaps-prior-constraints.md

| ID | Idea | Category | Justification | Applies to phase |
|---|---|---|---|---|
| A4→A3-001 | Pair the bidirectional helm↔irsa lint with a `runbook-orphan-irsa-debug.md` for when the lint fires — names the three fixes (delete role, add helm, mark intentional). | runbook | Lint without a fix-tree confuses operators. | 1+ |
| A4→A3-004 | Add a `pre-commit-hook` form of the strict-mode lint that prints the exact diff to apply — fixes get faster. | unit-test | Same lint, shorter loop. | 0+ |
| A4→A3-009 | Pair the `type: Format` lint with a quickfix mode that suggests the correct subtype based on adjacent patches. | unit-test | Lint + suggestion shortens the iteration over guessing. | 2+ |
| A4→A3-011 | Couple the `triggers_replace` SHA lint with `runbook-tf-data-zero-added.md` documenting how to verify the lint did its job after the next apply. | runbook | The bug is specifically a silent no-op; runbook is what confirms it's no longer silent. | 1+ |
| A4→A3-018 | Pair the IRSA trust-subject lint with `compare-irsa-trust-to-tf.yml` dispatch workflow (A4-068) — same invariant, live form. | dispatch-workflow | Author-time + runtime form catches drift from both directions. | 1+ |
| A4→A3-019 | Add a `runbook-deployment-runtime-config.md` that lists every step required to safely change a Provider's SA name (delete deploy, wait for re-render). | runbook | PR #68 hack was the proof that operators don't know this. | 2+ |
| A4→A3-029 | Pair the phase-2-diagnose dump-presence test with `runbook-diagnose-output-schema.md` describing every section's expected shape — failures point at the missing section. | runbook | Test catches missing sections; runbook explains what each should contain. | 2+ |
| A4→A3-031 | Pair the same-name-collision integration test with `runbook-asm-uid-naming.md` describing the rule (UID, not name). | runbook | Bug PR #59 root cause was operator-side; runbook codifies the rule. | 2+ |
| A4→A3-033 | Add a live `kyverno-drift-watch.sh` that polls every 5 min and posts a one-line summary to the dispatch-history doc — earliest possible warning. | shell-helper | Tests catch on next CI; live watch catches in 5 min. | 1+ |
| A4→A3-037 | After the provider-404 chainsaw scenario, also dump the registry lookup chain (resolved image, last-pulled digest) for triage. | chainsaw | The 404 may have multiple causes; dump narrows quickly. | 2+ |
| A4→A3-038 | Pair the 8-MR assertion with a `mr-status-table.yml` workflow (A4-083) form so the same shape is queryable on demand. | chainsaw | Test = author-time; workflow = runtime. | 2+ |
| A4→A3-042 | Have the canonical `wait_for` helper auto-quote its last-seen state on timeout in markdown form ready to paste into a PR comment. | refactor-test | Evidence-ready failure output saves a step. | 1+ |
| A4→A3-049 | Add a `runbook-aws-auth-debug.md` covering the OIDC vs static-creds bug surface — paired with the lint. | runbook | Lint catches misconfig; runbook explains the fix. | 0+ |
| A4→A3-050 | Pair the EKS log-types lint with `runbook-eks-logs-where.md` naming the CloudWatch log group per type. | runbook | Knowing the lint passed is not enough; operators need to find the data. | 1+ |
| A4→A3-061 | Add a `composition-pipeline-trace.sh` that prints step-by-step `crossplane render` output between pipeline steps — catches non-determinism at author time. | chainsaw | Same defense, shorter loop. | 2+ |

## For A5-orchestration-post-actions.md

| ID | Idea | Category | Justification | Applies to phase |
|---|---|---|---|---|
| A4→A5-001 | Pair parallel root applies with a `runbook-parallel-apply-debug.md` documenting how to attribute a failure to the right root when N applies are in flight. | runbook | Parallel without traceability is parallel chaos. | 0+ |
| A4→A5-002 | Add a `subagent-pool-status.md` auto-updated dashboard so the conductor's view is also the operator's view. | dashboard | Avoids the "what is the conductor thinking" debug class. | 0+ |
| A4→A5-007 | Pair the EKS watcher with a `notify-when-condition.sh` generic helper used everywhere — one tool, many uses. | shell-helper | Generic primitives outlive bespoke watchers. | 1+ |
| A4→A5-010 | Cache the speculative-plan JSON to a known path so the next agent can read it without re-running. | cache | Shaves another 20s every time. | 0+ |
| A4→A5-013 | Pair `argocd app sync` with `runbook-argocd-sync-failure.md` enumerating the five blockers (RBAC, sync-wave, CRD missing, hook fail, prune-conflict). | runbook | Sync errors are often opaque; runbook decodes them. | 1+ |
| A4→A5-018 | Have the background `kubectl wait` emit a `/tmp/wait-events.log` line per resource transition so a debugger can replay. | pipeline | Wait-in-background loses observability without a log. | 1+ |
| A4→A5-021 | Add a `wait-then-trigger.sh --on-fail` mode that runs a diagnose helper instead of just exiting — auto-debug on first failure. | pipeline | "Wait then trigger" is good; "wait then debug if fail" is better. | 0+ |
| A4→A5-027 | Make the event bus topology + topic list a one-page `event-bus-topics.md` runbook so subagents know what to subscribe to. | runbook | Buses without topic registries become noise. | 0+ |
| A4→A5-028 | Pair tmux panes with a `tmux-layout-phase-N.sh` script per phase that auto-arranges the panes for that phase's likely debug session. | orchestration | One command vs five tmux invocations. | 0+ |
| A4→A5-030 | Pipe `crossplane beta trace` stream output into the dispatch-history doc, so the trace becomes part of the session record. | pipeline | Ephemeral traces are forgotten; persistent ones become evidence. | 2+ |
| A4→A5-034 | Add a `argocd-app-sync-all-and-quote.sh` wrapper that emits a markdown-ready table of post-sync conditions, satisfying verify-evidence requirement. | parallel-apply | Sync without evidence-quote is the silent-pass class. | 2+ |
| A4→A5-037 | Have the status board auto-generate a final `session-gantt.svg` at session end for the handoff — visualizes wall-clock waste. | orchestration | Visual artifact drives next-session optimization. | 0+ |
| A4→A5-042 | Pair the back-pressure subagent with a `runbook-aws-throttle.md` listing the per-service throttle codes and recommended backoff multipliers. | runbook | Throttle detection without remediation is just complaining. | 0+ |
| A4→A5-047 | After local-kind chainsaw, auto-diff results vs the last real-cluster run — surfaces simulation drift early. | speculative-apply | Local-rehearsal is only useful if its accuracy is tracked. | 1+ |
| A4→A5-049 | Pair warm-pool VPCs with `warm-pool-status.sh` that asserts the warm VPC still matches sandbox quota and isn't itself the cap-killer. | prewarm | Warm pool can become orphan-leak; needs its own guardrail. | 0+ |

## For A6-removal-refactor.md

| ID | Idea | Category | Justification | Applies to phase |
|---|---|---|---|---|
| A4→A6-001 | Before deleting `ext-github`, capture the "one useful curl recipe" each skill contains into a `curl-recipes.md` so institutional memory survives. | documentation | Removing skills loses some useful patterns silently. | 0+ |
| A4→A6-007 | Replace `phase-2-diagnose.yml` with `scripts/phase-2-diagnose.sh` that emits the SAME section headings — preserves grep-compatibility of old PR comments. | refactor | Deleting outright breaks PR-search continuity. | 2+ |
| A4→A6-008 | Before deleting `chainsaw-verify.yml`, extract its SHA-pinning concept into `runbook-verify-then-pr.md` since the pattern is still occasionally useful. | documentation | Pattern outlives the workflow that implemented it. | 2+ |
| A4→A6-013 | Replace `post-comment.py` with a `gh pr comment --body-file` one-liner pattern documented in AGENTS.md — same outcome, fewer LoC. | refactor | Inline use-site documentation prevents future re-invention. | 0+ |
| A4→A6-018 | When collapsing `terraform-test.yml`, emit the same step-name structure in the new script's output so log-grep patterns survive. | refactor | Operators have muscle memory on the step names. | 0+ |
| A4→A6-029 | Keep `aws-creds-check.sh` as a single-line wrapper that ALSO checks region+account against sandbox-allowlist before delegating to `aws sts` — guardrail value beats LoC value. | refactor | Removing the guardrail risks a wrong-account apply. | 0+ |
| A4→A6-030 | Before deleting `k8s-logs.sh`, ensure its `--previous` flag handling is moved into the diag.sh subcommand so previous-container logs remain easy. | refactor | The flag is the one non-trivial bit; don't lose it. | 1+ |
| A4→A6-033 | When trimming `diag-component.sh`, keep one generic `component=any` branch that prints the standard kubectl triad — preserves the muscle memory entry point. | refactor | Removing the generic branch forces every operator to relearn. | 1+ |
| A4→A6-037 | Replace the "dispatch a workflow to read the cluster" rule with a positive-form `prefer-direct-kubectl.md` skill — codify the new pattern, don't just delete the old. | documentation | A removed rule leaves a gap; a replacement rule fills it. | 2+ |
| A4→A6-038 | When removing the v2.0.1 sentinel, add a `migration-checklist-crossplane-2.2.md` that lists every sentinel-removal and the verification probe per. | runbook | Workaround removals are a class of silent regressions. | 1+ |
| A4→A6-040 | When dropping multi-substrate language from AGENTS.md, add a one-line "if you find yourself wanting a bridge, see runbook-direct-access.md" pointer. | refactor | Future agents may resurrect bridges absent guidance. | 0+ |
| A4→A6-043 | When converting diagnose dump to cheatsheet, also add `make diagnose-bug-N` targets per known bug class so the cheatsheet is also executable. | consolidate-script | Cheatsheet that runs is better than cheatsheet that's read. | 2+ |
| A4→A6-045 | When dropping head_sha gating, add a `runbook-when-to-pin-sha.md` covering the two cases where it's still right (rollback, hotfix). | refactor | Removing the pattern entirely loses a real-but-rare use case. | 0+ |
| A4→A6-047 | When collapsing the Route53 zone discovery duplication, emit a single-source-of-truth value into `/tmp/sandbox-env.json` for all consumers. | dedupe | One file beats one function — file survives shell restarts. | 0+ |
| A4→A6-050 | Before removing `mcp__github__*` from allowed-tools lists, audit for any skill that quietly relies on a github MCP tool for read-only inspection — keep those. | refactor | Allow-list removal must be paired with use-site audit, else breakage. | 0+ |
