# Cross-review additions from A5

- Reviewer: A5 (orchestration & parallelization post-Actions)
- Date: 2026-05-25
- Branch: claude/determined-pasteur-53fAN
- Stance: additive-only — every suggestion extends, parallelizes, or composes with the target idea. No criticism.

## For A1-debug-tools-max-capability.md

| ID | Idea | Category | Justification | Applies to phase |
|---|---|---|---|---|
| A5→A1-001 | Run A1-001 `whereami.sh` once at session start AND export its outputs to `/tmp/session.env` so every subagent sources it instead of re-probing. | cache+prewarm | Avoids N subagents hammering STS/EKS describe at session start. | 0+ |
| A5→A1-002 | Phase-status probe (A1-002) can fan out per-phase with `make -j7 probe-phase-{0..6}`; each probe is independent. | parallel-probe | Critical path becomes max-probe-time not sum. | 0+ |
| A5→A1-003 | Stream EKS control-plane logs (A1-003) live into the conductor's event bus (A5-027) so audit denials trigger downstream subagents instantly. | pipeline | Turns CloudWatch logs into push not pull. | 1+ |
| A5→A1-004 | Run A1-014 dashboard creation in parallel with A1-015 + A1-016; all three are independent CloudWatch puts. | parallel-apply | Cuts dashboard-bootstrap from 3x serial to 1x. | 1+ |
| A5→A1-005 | A1-018 `irsa_trust_validator.py` fans out trivially: run it for every role concurrently (one subprocess per role). | parallel-probe | Eliminates the per-role serial loop suggested by today's bash patterns. | 1+ |
| A5→A1-006 | A1-019 `crossplane-trace.sh` should write to the event bus on each layer-flip so a watcher subagent can react to "MR appeared" without polling. | pipeline | Composes with A5-027/A5-030. | 2+ |
| A5→A1-007 | The terraform-postcheck verifiers (A1-025/026/027) can all run as a single `make -j` target after apply — independent IAM/Helm/Provider probes. | parallel-probe | Cuts post-apply verify from serial to parallel. | 1+ |
| A5→A1-008 | A1-033 `kubectl k8p` dispatcher can launch its subcommands in background by default (returning a handle), enabling pipelined diag. | pipeline | Subcommands become composable Unix-style. | 1+ |
| A5→A1-009 | A1-048 diag-bundle could run while phase apply is still in flight — the bundle script doesn't mutate, so it's safe to overlap. | speculative-probe | Pre-positions evidence so failures are diagnosable instantly. | 1+ |
| A5→A1-010 | A1-060 synthetic canary can be a long-lived background sandbox process triggered at session start rather than a Lambda — same signal, zero AWS spend. | prewarm | Composes with A5-007 watcher pattern. | 1+ |
| A5→A1-011 | A1-035 quota-check.sh is the perfect input to A5-042 back-pressure signal: emit a metric instead of a boolean. | orchestration | Lets parallel subagents self-throttle. | 0+ |
| A5→A1-012 | A1-069 `diag.sh` dispatcher should accept a `--parallel` flag that runs every specialist concurrently and merges output. | parallel-probe | "All-in" diag in one round trip. | 1+ |
| A5→A1-013 | A1-038 diff-state.sh can run continuously in the background as a watcher and notify on drift, rather than on-demand. | pipeline | Drift becomes push, not pull. | 1+ |

## For A2-integration-e2e-tests-max-capability.md

| ID | Idea | Category | Justification | Applies to phase |
|---|---|---|---|---|
| A5→A2-001 | A2-016 (20 parallel claims) can share a single kubeconfig via A5-032 to avoid 20 STS calls. | cache | Avoids STS rate-limit fan-out. | 2+ |
| A5→A2-002 | A2-003 IRSA simulate-principal-policy fans out: one async call per role, gather with asyncio. | parallel-test | Cuts N-role check from sum to max. | 1+ |
| A5→A2-003 | A2-018 soak test can run in background while A2-001 round-trip and A2-007 drift tests run in foreground — three independent tests, one wall-clock. | pipeline | Soak is wall-clock-bound, not CPU; overlap freely. | 2+ |
| A5→A2-004 | A2-019 90-min ArgoCD soak should be a session-start subagent so its result is ready when needed, not blocked on. | speculative-test | Hides 90 min behind everything else. | 1+ |
| A5→A2-005 | A2-039 (50 OIDC requests) and A2-049 Cognito browser-flow can share the same subagent pool launched once. | subagent-pool | Reuses auth-flow harness. | 5+ |
| A5→A2-006 | A2-022/A2-023/A2-024 chaos tests are independent failure injections — fan them out across one cluster simultaneously and assert each surfaces its own alarm. | parallel-test | Tests cross-blast-radius too. | 1+ |
| A5→A2-007 | A2-035 concurrency+chaos hybrid is the perfect input to A5-042 back-pressure subagent — feed throttle signals during the run. | orchestration | Surfaces realistic throttle behavior. | 2+ |
| A5→A2-008 | A2-053 ASM rotation test can be triggered by event bus the instant A2-001 round-trip subagent reports Ready, no sleep. | pipeline | Removes explicit wait. | 2+ |
| A5→A2-009 | A2-044 EKS-via-XRD validation should run against the kind rehearsal cluster (A5-040) first, in parallel with the real apply. | speculative-test | Catches composition bugs in seconds. | 3+ |
| A5→A2-010 | A2-008 forced-sync test fans out trivially across all apps with `argocd app sync --async` (A5-034). | parallel-test | Sum-of-N becomes max-of-N. | 1+ |
| A5→A2-011 | A2-046 spoke teardown enumeration can run in parallel with the spoke's own provisioning of the NEXT test claim. | pipeline | Cleanup tax disappears. | 3+ |
| A5→A2-012 | A2-050 (5-min cadence latency probe) should subscribe to the event bus and back off when A5-042 reports throttling. | orchestration | Cooperative load. | 2+ |
| A5→A2-013 | A2-001/002/044/045 claim-roundtrip tests share scaffolding — extract a "claim-rt-harness" subagent that all four call, instead of duplicating setup. | subagent-pool | DRY at the orchestration layer. | 2+ |
| A5→A2-014 | A2-028/029/030/031/032/033 contract tests are pure-static and can run in `make -j` at session start with zero AWS calls. | parallel-test | Free wall-clock win. | 1+ |
| A5→A2-015 | A2-012/013 CloudWatch oracle queries can be batched into a single Logs Insights multi-query call instead of two round trips. | cache | Halves CloudWatch API cost. | 2+ |

## For A3-test-gaps-prior-constraints.md

| ID | Idea | Category | Justification | Applies to phase |
|---|---|---|---|---|
| A5→A3-001 | All A3 unit/static lints (A3-001..A3-021, A3-039..A3-058) are pure-CPU and parallelize trivially under `make -j$(nproc)`. | parallel-test | Unit-test wall-clock drops from N×100ms to ~100ms. | 0+ |
| A5→A3-002 | A3-029 diagnose-completeness integration test can run on the kind rehearsal cluster (A5-040) instead of real EKS. | speculative-test | Zero AWS dependency. | 2+ |
| A5→A3-003 | A3-032 commit→ArgoCD-sync latency test should subscribe to the A5-027 event bus rather than poll for 3 min. | pipeline | Sub-second oracle. | 2+ |
| A5→A3-004 | A3-034..A3-038 chainsaw scenarios run today as one big harness — split into one-scenario-per-process and run with `xargs -P`. | parallel-test | N-scenario time becomes max-scenario time. | 2+ |
| A5→A3-005 | A3-042 (canonical wait_for library) should be the same helper as A5-043 (`await k8s/condition:...`); one DSL, two callers. | dedupe | Single source of truth across tests and orchestration. | 1+ |
| A5→A3-006 | A3-055 Composition revision-bump test can be triggered by event bus on every `git push` automatically. | pipeline | Continuous regression coverage. | 2+ |
| A5→A3-007 | A3-031 cross-namespace UID-collision test fans out by launching N claims in parallel with one subagent each. | parallel-test | Real concurrency, not sequential pseudo-concurrency. | 2+ |
| A5→A3-008 | A3-059 (run.sh `set -e` + dump) should call A5-037 phase status board on each failure so the dump lands in a known location. | orchestration | Discoverable evidence. | 1+ |
| A5→A3-009 | A3-008/A3-044 helm-render brittleness can be cached: render once at session start into `/tmp/helm-rendered/`, lints read from there. | cache | Avoids N redundant `helm template` calls. | 1+ |
| A5→A3-010 | A3-012/A3-048 chart-version drift checks can run as a pre-commit hook in addition to test-time, catching it 100x earlier. | pipeline | Shift-left. | 1+ |
| A5→A3-011 | A3-022..A3-028 Kyverno audit policies can be `kyverno test`'d in parallel against fixtures in `make -j`. | parallel-test | Policy lint becomes O(1) wall-clock. | 1+ |

## For A4-debug-tool-gaps-prior-constraints.md

| ID | Idea | Category | Justification | Applies to phase |
|---|---|---|---|---|
| A5→A4-001 | A4-001 `read-cluster.yml` becomes a single sandbox alias `kc-read`; under A5 orchestration the dispatch wrapper is moot, but the JSON output schema is still valuable for subagent consumption. | refactor | Preserves the contract, drops the substrate. | 1+ |
| A5→A4-002 | A4-004 `status-snapshot.yml` should run as a background subagent at session start (A5-007 pattern), populating `/tmp/snapshot/` so any later question reads from a hot cache. | prewarm+cache | Snapshot is ready before asked. | 1+ |
| A5→A4-003 | A4-005 crossplane-trace can stream to A5-027 event bus per layer-traversal, enabling reactive subagents downstream. | pipeline | Trace becomes a stream not a dump. | 2+ |
| A5→A4-004 | A4-016 phase-state-probe is the same probe as A5→A1-002 — run it as one parallel `make -j7` job. | dedupe | One probe, two callers (A1 + A4). | 0+ |
| A5→A4-005 | A4-021 pod-restart-watch should be a long-lived watcher subagent subscribed to the cluster-events stream, not a one-shot. | pipeline | Push not poll. | 1+ |
| A5→A4-006 | A4-036 cluster-state-bundle should run in parallel with apply so the bundle is up-to-date on apply completion. | speculative-probe | Bundle ready when needed. | 1+ |
| A5→A4-007 | A4-038/A4-039/A4-040 wait-for-* helpers are all instances of A5-043 (`await condition:... && cmd`) — implement once, reuse. | dedupe | Unified DSL. | 1+ |
| A5→A4-008 | A4-058 secret-staleness scan runs in parallel across all namespaces (one subprocess per ns) instead of one sweep. | parallel-probe | NS-count parallelism free. | 1+ |
| A5→A4-009 | A4-068 IRSA-trust diff is independent per role — fan out with `xargs -P` over `aws iam list-roles` output. | parallel-probe | Cuts N-role diff to max-role. | 1+ |
| A5→A4-010 | A4-082 dispatch cookbook should also document the parallel-fan-out idiom for every read workflow. | runbook | Embeds A5 patterns in muscle memory. | 0+ |
| A5→A4-011 | A4-100 golden-snapshot-diff plus A5-040 kind rehearsal cluster: keep one golden per cluster type, diff in parallel. | parallel-test | Multi-cluster regression in one round. | 1+ |
| A5→A4-012 | A4-099 orphan-resource scan can run continuously in background as a quota guardian (composes with A1-037 alarm). | pipeline | Continuous quota safety. | 0+ |
| A5→A4-013 | A4-060 last-N-failed-runs becomes "tail the event bus for failure events" once A5-027 is in place — zero gh-api round trips. | pipeline | Event bus subsumes the workflow. | 0+ |

## For A6-removal-refactor.md

| ID | Idea | Category | Justification | Applies to phase |
|---|---|---|---|---|
| A5→A6-001 | After A6-018 collapses the terraform-test matrix, the resulting `scripts/terraform.sh` is the natural place to add A5-036's `-parallelism=30` default. | refactor | One canonical entrypoint, parallel by default. | 0+ |
| A5→A6-002 | A6-019 (one-shot bootstrap script) pairs with A5-039 (pre-create backend at account-rotation): same operation, prewarm form. | prewarm | Bootstrap moves out of every run. | 0+ |
| A5→A6-003 | A6-010 inlining integration-tests.yml into `scripts/run-integration.sh` enables A5→A3-004 parallel scenario fan-out (workflow steps can't fan out, scripts can). | parallel-test | Removing the workflow unlocks parallelism. | 2+ |
| A5→A6-004 | A6-023 removal of unit-tests.yml lets unit tests run under `make -j$(nproc)` per A5→A3-001 — workflow steps were serial. | parallel-test | Removing the workflow unlocks CPU parallelism. | 0+ |
| A5→A6-005 | A6-046 (test_chainsaw_kind_config removal) composes with A5-047 — kind chainsaw runs at session start as a background subagent. | speculative-test | Live exercise replaces static lint. | 2+ |
| A5→A6-006 | A6-026/A6-027 concurrency-block removal aligns with A5-002/A5-014: one-agent-per-resource is the new model, multi-runner protection is moot. | simplify | Concurrency model shifts substrate. | 2+ |
| A5→A6-007 | A6-037 (handoff rule update) should also reference A5-013 (kick `argocd app sync --prune` immediately) as the replacement pattern. | refactor | Replaces dispatch idiom with sandbox idiom. | 2+ |
| A5→A6-008 | A6-043 cheatsheet (replacing phase-2-diagnose sections) should embed the A5-027 event-bus subscriptions so devs can stream evidence not query for it. | refactor | Cheatsheet becomes live, not static. | 2+ |
| A5→A6-009 | A6-016 (compute-gates → Makefile) is the natural home for A5-003 `make -j8 phase-N` parallel targets. | consolidate-script | Makefile already wanted; A5 adds parallel targets. | 0+ |
| A5→A6-010 | A6-044 (`make chainsaw`) is the same Makefile as A5→A6-009 and A5-003 — one Makefile, three callers. | dedupe | Single Makefile is the orchestration plane. | 2+ |
| A5→A6-011 | A6-045 (drop `head_sha` gating) enables A5-007 watcher-driven hand-off, since the agent no longer needs to manually pin SHAs. | refactor | Removes manual gate enabling event-driven pipeline. | 0+ |
| A5→A6-012 | A6-047 (dedupe Route53 zone discovery) writes the answer once into `/tmp/session.env` per A5→A1-001 — same cache, two callers. | dedupe | Reinforces the session-env pattern. | 0+ |
| A5→A6-013 | A6-038/A6-039 (Crossplane workaround removals) unlock A5-014 (parallel provider install + IRSA pre-create) by removing the manual deployment-delete hack from the chain. | parallel-apply | Workaround removal restores DAG parallelism. | 1+ |
| A5→A6-014 | A6-012 (PHASE-2-LIFECYCLE-PLAN → script) is the natural input to A5-023 phase compiler — feed the script's steps as a YAML manifest. | orchestration | Lifecycle becomes the declarative input. | 2+ |
| A5→A6-015 | A6-024 (single bats-style unit runner) gains free parallelism from bats's built-in `-j` flag, no extra work to align with A5→A3-001. | parallel-test | Tool already supports the model. | 0+ |
