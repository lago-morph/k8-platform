# A5 — Orchestration & Parallelization Brainstorm (post-Actions sandbox)

- Agent: A5
- Mandate: Brainstorm orchestration/parallelization wins enabled by running terraform/kubectl/aws directly from the sandbox instead of via GitHub Actions, covering phases 0 → 6.
- Date: 2026-05-25
- Branch: claude/determined-pasteur-53fAN

| ID | Idea (one sentence) | Category | Justification | Applies to phase |
|---|---|---|---|---|
| A5-001 | Split `terraform/base` into independent `vpc/`, `route53/`, `acm/`, `cognito/` root modules and `terraform apply` them in parallel from the sandbox. | parallel-apply | Today phase-0 is one serial graph (~5 min); VPC and Cognito share nothing, so concurrent applies cut the critical path to whichever is slowest. | 0+ |
| A5-002 | Launch a subagent pool of N workers, each owning one terraform root, coordinated by a "conductor" agent that holds the dependency DAG. | subagent-pool | Removes the single-agent serialization bottleneck inherent in the current "one bash at a time" loop. | 0–6 |
| A5-003 | Generate a Makefile-style `targets` file from a YAML phase manifest so `make -j8 phase-0` runs every leaf in parallel automatically. | dependency-graph | Pushes parallel scheduling down to a battle-tested tool instead of bespoke orchestration. | 0–6 |
| A5-004 | Pre-cache Helm chart tarballs (`helm pull` for argo-cd, crossplane, kyverno, ingress-nginx, cert-manager) into `/tmp/charts` in parallel while EKS is still being created. | prewarm | Saves the ~30–60 s of serial chart downloads at the start of phase-1 helm_release steps. | 1+ |
| A5-005 | Pre-pull provider Docker images (`crossplane/provider-aws-secretsmanager`, `function-patch-and-transform`) onto the node group via a DaemonSet manifest applied the instant EKS reports Ready. | prewarm | Provider install today blocks on first-pull from upbound; warming the layer cache shaves a minute off composite-Ready. | 1+ |
| A5-006 | Run `aws eks update-kubeconfig` inside the terraform apply via a `local-exec` so kubectl is hot the second the cluster API is reachable, no manual step. | local-tf-driver | Eliminates the human "wait then run kubeconfig" gap and lets phase-2 verification start immediately. | 1+ |
| A5-007 | Dispatch a "watcher" subagent that polls `aws eks describe-cluster` and emits a notification the millisecond status flips to ACTIVE so the next phase can fire. | pipeline | Removes fixed-duration `sleep 600` style waits in favor of event-driven hand-off. | 1+ |
| A5-008 | Use multiple terraform workspaces against the same backend so two sandboxes (or two tabs) can hold different cluster bring-ups concurrently without state collision. | orchestration | Lets one engineer A/B two compositions in parallel sandboxes instead of tearing down between runs. | 0–6 |
| A5-009 | Compile a "phase plan" graph from `depends_on`/remote_state references and emit a topologically-sorted DOT file plus a parallel execution schedule. | dependency-graph | Surfaces hidden serial chokepoints that today are invisible inside one terraform graph. | 0–6 |
| A5-010 | Run `terraform plan -refresh=false` speculatively in background while waiting on apply so the next phase's plan is ready instantly. | speculative-apply | Hides plan latency (~20 s) behind apply latency that's already happening. | 0–6 |
| A5-011 | Spin up a localstack-or-moto twin and run a dry-rehearsal apply against it in parallel with the real AWS apply, surfacing config errors 30 s in instead of 5 min in. | speculative-apply | Catches typos and bad refs before they burn real wall-clock on real AWS rate-limits. | 0–6 |
| A5-012 | Pre-warm a Keycloak realm-config JSON in parallel with the ingress provisioning so the moment ingress is up, the realm import takes ~2 s. | prewarm | Today realm config is authored only after ingress; doing it concurrently removes a serial leg. | 4+ |
| A5-013 | Kick `argocd app sync --prune` for `bootstrap` immediately when the helm_release lands, instead of waiting for the 3-min refresh window. | pipeline | Cuts the well-documented 3-minute ArgoCD sync wait described in handoff Step 4. | 1+ |
| A5-014 | Have one subagent install Crossplane providers while a sibling subagent pre-creates the IRSA roles those providers need, joining at the SA-annotation step. | parallel-apply | Today both happen in a single helm.tf serial chain; splitting cuts ~90 s. | 1+ |
| A5-015 | Use `terraform apply -target=...` per leaf resource across N parallel terraform invocations sharing a single state via `-lock-timeout`. | parallel-apply | Lets one root module exploit intra-module parallelism beyond terraform's default `-parallelism=10`. | 0–6 |
| A5-016 | Adopt Terragrunt's `run-all apply` with explicit `dependencies` blocks to get DAG-aware parallel applies across roots for free. | dependency-graph | Replaces hand-rolled phase scripts with a tool whose entire reason for existing is this problem. | 0–6 |
| A5-017 | Maintain a long-lived "infrastructure shell" subagent whose only job is `terraform apply` calls, freeing the main agent to read logs concurrently. | subagent-pool | Today the main loop blocks on apply for 5–15 min; offloading reclaims that wall-clock. | 0–6 |
| A5-018 | Fire `kubectl wait --for=condition=...` in a background process the second a manifest is applied, so verification overlaps with the next apply. | pipeline | Removes the "apply → wait-for-ready → next apply" anti-pattern. | 1–6 |
| A5-019 | Pre-create the ACM cert (long DNS-validation tail) at session start so it's ISSUED by the time anything actually needs it. | prewarm | ACM validation is the longest single wait in phase-0; starting it first overlaps with everything. | 0+ |
| A5-020 | Stand up Crossplane providers via `kubectl apply` directly (not helm) while helm is still installing argo-cd, since they share no controllers. | parallel-apply | Breaks the current helm-then-helm-then-crossplane chain in `terraform/management/helm.tf`. | 1+ |
| A5-021 | Use a "chained wait-then-trigger" CLI (e.g. `until kubectl get ... ; do sleep 2; done && next-cmd`) launched in background per phase boundary. | pipeline | Replaces manual checking with event hooks the agent can subscribe to via Monitor. | 0–6 |
| A5-022 | Treat `terraform/base` outputs as a static manifest, regenerate once, and serve to phase 1 via a local file instead of `terraform_remote_state` reading from S3 every plan. | cache | Removes the S3 GET round-trip on every phase-1 plan/apply. | 1+ |
| A5-023 | Build a "phase compiler" that takes a YAML high-level plan ("bring up mgmt with secrets+keycloak") and emits parallel terraform + kubectl + argocd commands. | orchestration | Codifies the bring-up sequence so any agent (or human) can replay it deterministically. | 0–6 |
| A5-024 | Cache `terraform init`'s `.terraform/providers/` in a shared volume across roots so each root doesn't re-download hashicorp/aws 600 MB. | cache | First `init` per root costs ~30 s today; shared cache makes subsequent inits ~2 s. | 0–6 |
| A5-025 | Run `terraform validate && tflint` in parallel across all roots at session start as a pre-flight before any apply. | speculative-apply | Catches syntactic errors in zero AWS wall-clock instead of mid-apply. | 0–6 |
| A5-026 | Pre-render every Helm chart with `helm template` against `--api-versions` and run `kyverno test` locally in parallel with the real cluster apply. | speculative-apply | Catches policy violations before they cause Sync failure on the real cluster. | 1+ |
| A5-027 | Maintain a Redis/SQLite "event bus" in `/tmp` that subagents post phase-completion events to, so listeners trigger downstream work without polling. | pipeline | Eliminates polling overhead and lets dozens of downstream tasks subscribe to one event. | 0–6 |
| A5-028 | Use `tmux` panes (or a TUI) so the human can watch base-apply, mgmt-apply, helm-install, and argo-sync logs side by side instead of reading one giant log. | orchestration | Improves human verification latency from "scroll a 170 KB log" to "glance at pane 3". | 0–6 |
| A5-029 | Push ArgoCD `Application` manifests into the cluster *before* the workloads exist, so they go OutOfSync→Synced automatically the moment CRDs land. | speculative-apply | Removes the explicit "now apply this Application" hand-off step from each phase. | 2–6 |
| A5-030 | Use `crossplane beta trace` or a custom controller-runtime watcher to stream XR/MR condition changes live to the agent's stdout. | pipeline | Replaces `phase-2-diagnose.yml`'s batch snapshot with continuous evidence. | 2+ |
| A5-031 | Have one subagent run end-to-end teardown of a previous test namespace while another brings up the next test claim — no serial cleanup tax. | parallel-apply | Cleanup currently blocks the next iteration for ~30 s per claim. | 2–6 |
| A5-032 | Cache `aws-iam-authenticator` / `aws eks get-token` tokens for kubectl across subagents via `KUBECONFIG=/tmp/shared-kubeconfig`. | cache | Avoids each agent re-hitting STS and burning the 6/s rate limit. | 1–6 |
| A5-033 | Drive a "speculative phase-3" apply against a scratch namespace while phase-2 is still settling, then promote if upstream succeeds. | speculative-apply | Hides phase-3 wall-clock under phase-2's tail. | 3+ |
| A5-034 | Use `argocd app sync --async` for every Application in one shot, then `argocd app wait` in parallel, instead of one-at-a-time sync. | parallel-apply | Trivially cuts N-app reconcile time from sum-of-N to max-of-N. | 2–6 |
| A5-035 | Pre-build a self-signed CA + Cognito client config in the sandbox and inject as a TF variable so phase-1 doesn't have to mint these mid-apply. | prewarm | Removes a serial AWS-API leg from inside the management apply. | 1+ |
| A5-036 | Add a `terraform apply -auto-approve -compact-warnings -parallelism=30` wrapper script that's the canonical entrypoint, bumping the default 10. | local-tf-driver | Cheapest single throughput win; AWS API rate limits, not terraform's default, are the real ceiling. | 0–6 |
| A5-037 | Maintain a "phase status board" markdown file that subagents append to as they finish, giving a real-time gantt of the bring-up. | orchestration | Gives both human and the conductor agent a single pane for "where are we". | 0–6 |
| A5-038 | Use AWS SDK pagination + `aws cloudformation` events-style polling (or `aws ec2 wait`) directly instead of terraform's internal polling. | local-tf-driver | Sometimes terraform polls every 30 s; direct waiters poll every 5 s. | 0–6 |
| A5-039 | Pre-create the S3 backend bucket + DynamoDB lock table once at account-rotation time and bake their names into the sandbox env, eliminating bootstrap. | prewarm | Removes the awkward "chicken-and-egg" backend bootstrap from every fresh account. | 0+ |
| A5-040 | Run a "rehearsal cluster" on kind/k3d locally in parallel with the real EKS bring-up, so Crossplane composition logic is verified without AWS latency. | speculative-apply | Decouples composition-function iteration from EKS-creation wall-clock. | 2+ |
| A5-041 | Use `kubectl apply --server-side --force-conflicts` in a fan-out across all CRDs at once instead of letting ArgoCD reconcile them serially. | parallel-apply | ArgoCD applies in waves; direct fan-out collapses waves into one round trip. | 2–6 |
| A5-042 | Have one subagent watch CloudWatch metrics live (AWS API throttling, EKS API latency) and feed back-pressure signals to other subagents. | orchestration | Prevents N parallel agents from collectively tripping AWS rate limits. | 0–6 |
| A5-043 | Build a "trigger-on-condition" wrapper: `await k8s/condition:Ready/<resource> && cmd` so chained pipelines read like a Makefile. | pipeline | DSL clarity makes complex bring-up sequences reviewable. | 1–6 |
| A5-044 | Cache `helm dependency build` output across sessions in the repo (`charts/.cache/`) so chart deps don't re-resolve every fresh sandbox. | cache | Saves ~10 s per chart, x5 charts = 50 s per fresh sandbox. | 1+ |
| A5-045 | Use `terraform state pull` once, then operate on a local copy in parallel speculative plans, and only `state push` when confirmed. | speculative-apply | Lets multiple "what-if" plans run without contending on the real state lock. | 0–6 |
| A5-046 | Fire phase-2 ArgoCD bootstrap manifest as a `kubernetes_manifest` *inside* the management terraform so it's atomic with the helm release. | orchestration | Removes a manual hand-off; bring-up becomes one `terraform apply`. | 1–2 |
| A5-047 | Run `chainsaw` smoke tests against a kind cluster in parallel with the real apply so policy regressions surface in seconds, not minutes. | speculative-apply | Today chainsaw runs only via CI workflow; local-parallel collapses the feedback loop. | 1–6 |
| A5-048 | Convert phase 2's "wait 3 min for ArgoCD refresh" into a `argocd app sync --hard-refresh` triggered the instant a manifest commit lands. | pipeline | The single biggest documented wait (handoff Step 4) becomes a sub-second push. | 2+ |
| A5-049 | Introduce a "warm pool" of pre-applied phase-0 VPCs left running between sessions (within sandbox limits) so phase-1 can start without phase-0 wait. | prewarm | Saves the entire 5-min phase-0 critical path when iterating on phase-1/2 fixes. | 0–1 |
| A5-050 | Use `terraform import` + `terraform refresh` against a pre-existing warm VPC instead of recreating it, so phase-1 attaches to an extant network. | speculative-apply | Even bigger win than A5-049: zero phase-0 wall-clock at all. | 0–1 |

## Cross-review additions

Additive, collaborative extensions from every other agent and the primary orchestrator. No criticism — only amplifications, related ideas, pairings, and meta-observations.

### from A1

| ID | Idea | Category | Justification | Applies to phase |
|---|---|---|---|---|
| A1→A5-001 | Pair A5-002 (subagent pool) with a per-subagent structured-log stream tagged with subagent-id + correlation-id, aggregated to a single live tail. | observability-pair | Parallel agents become illegible without per-agent stream tagging. | 0–6 |
| A1→A5-002 | Extend A5-007 (EKS-Ready watcher) to also assert audit-log delivery is flowing within 60s of Ready — proves observability is up, not just API. | observability-extension | A cluster that's Ready but not logging is half-broken. | 1+ |
| A1→A5-003 | Pair A5-011 (localstack rehearsal) with diff'ing localstack's CloudTrail-equivalent against real CloudTrail post-apply to catch API behaviors localstack doesn't model. | speculative-apply-extension | Surfaces localstack-vs-AWS divergence as a known set. | 0–6 |
| A1→A5-004 | Extend A5-016 (Terragrunt run-all) with a Gantt chart artifact per session showing actual parallelism achieved vs theoretical maximum. | observability-extension | Visualizes critical path so it can be optimized. | 0–6 |
| A1→A5-005 | Pair A5-027 (event bus) with an OpenTelemetry collector so each event is a span, queryable in Jaeger/Tempo. | pipeline-extension | Free distributed tracing of the orchestration graph itself. | 0–6 |
| A1→A5-006 | Extend A5-030 (live XR/MR condition stream) with a TUI dashboard (e.g. `k9s` plugin or bespoke) that highlights condition flips with timestamps. | pipeline-extension | Human pattern-recognition kicks in when state changes are visualized. | 2+ |
| A1→A5-007 | Pair A5-037 (status board markdown) with an auto-generated svg gantt embedded so PR reviewers see parallelism, not just text. | orchestration-extension | Visual evidence of orchestration wins makes them defensible. | 0–6 |
| A1→A5-008 | Add an "orchestration-as-code" lint asserting every parallel-eligible terraform root declares `# parallel-safe-with: [...]` so future refactors can re-derive the DAG. | orchestration-extension | Implicit parallelism becomes self-documenting. | 0–6 |
| A1→A5-009 | Pair A5-042 (rate-limit back-pressure) with auto-emitting CloudWatch custom metrics `OrchestratorBackpressureEvents` so throttling is graphable. | observability-pair | Proves the back-pressure actually fires when AWS APIs get hot. | 0–6 |
| A1→A5-010 | Extend A5-049/050 (warm pool VPCs) with a daily tag-audit job asserting all warm pool resources still carry `lifecycle=warm` — defends against accidental promotion to ephemeral. | prewarm-extension | Warm pool resources getting GC'd by cleanup scripts is the obvious risk. | 0–1 |
| A1→A5-011 | Pair A5-048 (hard-refresh on commit) with an emitted "sync latency" metric per Application so the speedup is provable and regression-able. | pipeline-extension | Without metrics, the win evaporates over time. | 2+ |
| A1→A5-012 | Add a `phase-bring-up-replay.sh` that takes a session ID and re-runs the exact dispatch sequence from the orchestrator log — turns sessions into reproducible tapes. | orchestration | Reproducibility is the second-order win of recording orchestration. | 0–6 |
| A1→A5-013 | Pair A5-040 (kind rehearsal cluster) with a webhook that auto-promotes a successful kind run to a real-EKS dispatch — closes the loop. | speculative-apply-extension | Two-step "rehearse then promote" eliminates the manual gate. | 2+ |
| A1→A5-014 | Extend A5-018 (background kubectl-wait) with structured exit-status persistence to `/tmp/wait-results.json` so the conductor can join on multiple waits. | pipeline-extension | Conductor-pattern needs a join primitive. | 1–6 |
| A1→A5-015 | Add a sandbox-wide AWS API rate dashboard (CloudWatch metric on `ThrottlingException` counts per service) so the rate-limit ceiling is visible, not just guessed. | observability | Knowing the actual ceiling enables max-parallelism tuning. | 0–6 |

### from A2

| ID | Idea | Category | Justification | Applies to phase |
|---|---|---|---|---|
| A2→A5-001 | Add a smoke test that runs A5-001 (split base parallel applies) and asserts total wall-clock < 60% of the serial baseline. | smoke-test | Locks in the orchestration win as a measurable contract. | 0+ |
| A2→A5-002 | Add an e2e idempotency test for A5-003 (Makefile -j parallel): run `make -j8 phase-0` twice and assert second run is a no-op. | new-scenario | Parallel orchestration must remain idempotent. | 0+ |
| A2→A5-003 | Build a chaos variant of A5-007 (event-driven watcher) that injects a transient cluster failure and asserts the watcher correctly retries rather than firing prematurely. | new-scenario | Event-driven hand-offs must tolerate flakes. | 1+ |
| A2→A5-004 | Add an A2-style soak around A5-013 (immediate ArgoCD sync) that fires it 100 times in a row and asserts no sync queue starvation. | smoke-test | Fast-path sync mustn't break under volume. | 1+ |
| A2→A5-005 | Pair A5-011 (localstack rehearsal) with an A2 contract test that asserts the rehearsal apply graph matches the real apply graph node-for-node. | smoke-test | Localstack rehearsal is only valuable if shape-faithful. | 0+ |
| A2→A5-006 | Add a concurrency test on top of A5-015 (per-leaf -target parallel apply) that confirms no state-lock collision under 8 parallel invocations. | smoke-test | The shared-state pattern is fragile; needs explicit coverage. | 0+ |
| A2→A5-007 | Use A5-027 (Redis/SQLite event bus) as the substrate for the A2 e2e suite's test-orchestrator coordinating chaos+claim+verification subagents. | test-oracle-promotion | Same event bus drives ops and tests. | 0+ |
| A2→A5-008 | Add a smoke test that A5-029 (pre-staged ArgoCD apps) transitions OutOfSync→Synced within deadline once CRDs land — assert via ArgoCD admin API. | smoke-test | Speculative-apply pattern only works if the eventual sync actually happens. | 2+ |
| A2→A5-009 | Build a chaos companion to A5-030 (live XR/MR streamer) that kills the streamer mid-stream and asserts the agent's downstream consumer reconnects cleanly. | smoke-test | Long-lived streams break; reconnect must be tested. | 2+ |
| A2→A5-010 | Pair A5-034 (`argocd app sync --async` fan-out) with a concurrency test that asserts no app is stuck in `Progressing` past deadline. | smoke-test | Fan-out can starve individual apps; test catches it. | 2+ |
| A2→A5-011 | Add an e2e harness on top of A5-040 (kind rehearsal cluster) that runs the entire A2 chaos suite locally before the real-EKS run. | new-scenario | Two-cluster discipline halves real-EKS feedback loop. | 2+ |
| A2→A5-012 | Add a soak test around A5-042 (CloudWatch back-pressure feedback) that runs 20 subagents in parallel for 30 min asserting zero AWS throttle errors. | smoke-test | Back-pressure controller must work under sustained load. | 0+ |
| A2→A5-013 | Use A5-043 (await-condition DSL) as the canonical wait primitive in every A2 e2e scenario. | test-oracle-promotion | Same DSL for ops and tests. | 1+ |
| A2→A5-014 | Add a contract test that A5-046 (atomic helm+bootstrap apply) leaves the cluster in the same final state as the two-step path. | smoke-test | Consolidation must not regress final state. | 1+ |
| A2→A5-015 | Add a teardown e2e that confirms A5-049/A5-050 (warm VPC pool) can be safely imported then destroyed without orphans. | smoke-test | Warm-pool patterns introduce orphan risk; explicit teardown test. | 0+ |

### from A3

| ID | Idea | Category | Justification | Applies to phase |
|---|---|---|---|---|
| A3→A5-001 | Pair A5-001 (parallel base applies) with a post-apply contract test that VPC + Cognito outputs are written atomically — race-condition consumers fail otherwise. | regression-extension | Parallel applies introduce a new "outputs not all written" bug class worth testing for. | 0+ |
| A3→A5-002 | Extend A5-007 (event-driven cluster-Ready watcher) to also emit a `cluster-API-reachable` event (separate from ACTIVE) — ACTIVE doesn't mean kubectl works. | regression-extension | Historical bug class: ACTIVE then 5xx for a minute. | 1+ |
| A3→A5-003 | A5-013 (`argocd app sync` on helm landing) deserves a chaos test that runs sync before the helm release finishes settling — proves sync is idempotent or fails loudly. | regression-extension | Catches sync-too-early race that today is hidden by the 3-min wait. | 1+ |
| A3→A5-004 | Pair A5-019 (pre-create ACM cert) with a verification that the cert's DNS validation record is in Route53 BEFORE waiting on ISSUED — speeds up failure detection. | regression-extension | Validation hang is silent; pre-checking the CNAME is the fast oracle. | 0+ |
| A3→A5-005 | A5-024 shared provider cache should have a contract test that the cache directory's provider versions match what each root's `versions.tf` declares — silent-mismatch guard. | regression-extension | Shared caches introduce cross-root version-coupling bugs. | 0+ |
| A3→A5-006 | Extend A5-027 (event bus) with a "deadletter" log: events with no subscriber within deadline trigger an alarm — invisible orchestration bugs become visible. | regression-extension | Missed-event class is the hardest event-driven bug to debug. | 0+ |
| A3→A5-007 | A5-029 (pre-applied Applications) needs a regression test that an Application sitting in OutOfSync for >N minutes (because CRD never landed) becomes a hard failure, not silent waiting. | regression-extension | Pre-applied Apps can sit forever; need a deadline. | 2+ |
| A3→A5-008 | Pair A5-034 (parallel argocd sync --async) with a per-app timeout map so one slow app doesn't mask successes — catches the "1/15 stuck" pattern. | regression-extension | Aggregate "max" hides single-app stuck cases. | 2+ |
| A3→A5-009 | A5-040 (rehearsal kind cluster) should snapshot composition function inputs from the rehearsal and diff them against the real EKS run — proves equivalence. | regression-extension | Kind rehearsal is only valuable if proven equivalent to EKS. | 2+ |
| A3→A5-010 | Extend A5-042 (backpressure watcher) with a regression test that throttling above threshold actually causes subagents to slow down — the watcher must demonstrably feed back. | regression-extension | Backpressure systems are notorious for silently not back-pressuring. | 0+ |
| A3→A5-011 | Pair A5-046 (atomic Application via kubernetes_manifest) with a tear-down test asserting `terraform destroy` cleanly removes the Application without leaving cluster-side orphan. | regression-extension | kubernetes_manifest has historical destroy-time edge cases. | 1-2 |
| A3→A5-012 | A5-049/A5-050 (warm pool / import existing VPC) need a session-start invariant test that the warm pool VPC matches the expected CIDR and subnet count — drift after import is silent. | regression-extension | Imported state can mismatch source-of-truth; explicit assert is cheap. | 0-1 |
| A3→A5-013 | Extend A5-017 (long-lived TF shell subagent) with a heartbeat assertion: if no apply within N min, exit — prevents zombie subagents from holding state locks. | regression-extension | Hung subagents holding DynamoDB locks are a known sandbox stall pattern. | 0+ |

### from A4

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

### from A6

| ID | Idea | Category | Justification | Applies to phase |
|---|---|---|---|---|
| A6→A5-001 | Once A5-006 (kubeconfig via local-exec) lands, retire the manual "run aws eks update-kubeconfig" step from every phase runbook. | simplification | One less hand-off step. | 1+ |
| A6→A5-002 | A5-013 + A5-048 (kick ArgoCD sync immediately / hard-refresh) lets us delete every `sleep 180` waiting for ArgoCD's 3-min refresh window in scripts and tests. | simplification | Event-driven replaces fixed sleeps. | 1+ |
| A6→A5-003 | A5-016 (Terragrunt run-all) supersedes A5-001, A5-002, A5-003, A5-009, A5-015, and A5-023 — adopting it lets us delete all the bespoke orchestration scaffolding. | refactor | One tool replaces six homegrown ideas. | 0+ |
| A6→A5-004 | A5-018 (background `kubectl wait`) lets us remove the explicit "wait for X" steps from sequential apply scripts; verification overlaps for free. | simplification | Removes serial-wait pattern. | 1+ |
| A6→A5-005 | A5-027's event bus retires every polling loop in scripts/ — they become subscribers. | refactor | Push > poll. | 0+ |
| A6→A5-006 | A5-046 (atomic ArgoCD bootstrap inside terraform) lets us delete the separate `bootstrap-argocd.sh` script and its accompanying handoff step. | simplification | One apply, one outcome. | 1+ |
| A6→A5-007 | A5-022 (cache base outputs locally) lets us remove the `terraform_remote_state` data source from phase-1 modules, simplifying graph + reducing S3 chatter. | refactor | Local file > remote_state for static outputs. | 1+ |
| A6→A5-008 | A5-029 (apply Applications pre-CRD) lets us delete the explicit sync-wave annotations on a chunk of `argocd/apps/*.yaml` — natural ordering handles it. | simplification | Eventual-consistency obviates wave hints. | 2+ |
| A6→A5-009 | A5-034 (`argocd app sync --async` fan-out) replaces the per-app serial sync script in any current bring-up automation. | refactor | Trivially parallel. | 2+ |
| A6→A5-010 | A5-049 + A5-050 (warm pool / import) lets us delete the phase-0 step from session bring-up checklists entirely when iterating downstream. | simplification | Skip-phase-0 becomes the default fast path. | 0+ |
| A6→A5-011 | A5-039 (pre-baked S3/Dynamo backend) retires the chicken-and-egg `bootstrap-backend.sh` and its README section. | simplification | One-time setup, never reinvoked. | 0+ |
| A6→A5-012 | A5-037 (live status board) makes the manual handoff "what's the current state" prose section much shorter — board is the source of truth. | simplification | Generated > written. | 0+ |
| A6→A5-013 | A5-007 (event-driven cluster-ready watcher) plus A5-027 (event bus) lets us delete every `sleep 600` style fixed wait remaining in phase scripts. | refactor | All waits become event subscriptions. | 1+ |
| A6→A5-014 | A5-024 (shared `.terraform/providers/` cache) lets us remove per-root `terraform init` from the documented bring-up steps — first session sets up, subsequents inherit. | simplification | Cache hides the step. | 0+ |
| A6→A5-015 | A5-036 (canonical apply wrapper with -parallelism=30) lets us delete every per-script terraform-flags string and consolidate flag policy in one place. | refactor | One wrapper, one policy. | 0+ |

### from PRIMARY

| ID | Idea | Category | Justification | Applies to phase |
|---|---|---|---|---|
| P→A5-001 | A `scripts/orchestrate/phase-graph.json` that declares phase × component DAG; a `phase-up.py` reads it and runs everything that can run in parallel at each frontier, with a Gantt-style progress dashboard. | dependency-graph | Codifies parallelism so future agents don't have to rediscover it. | 0+ |
| P→A5-002 | A "warm pool" subagent that, while phase-1 EKS is creating (15 min), pre-pulls every Helm chart, pre-renders every manifest, pre-validates every IAM policy doc, and pre-warms ECR images — net zero wall-clock cost. | parallel-apply | Captures the explicit "parallel unrelated work" insight from the user's prompt. | 1+ |
| P→A5-003 | Use the existing two-AZ constraint to deliberately structure modules so AZ-A and AZ-B resources can be applied as two parallel `terraform apply -target=` invocations. | parallel-apply | Same wall-clock budget gets twice the work done; safe within sandbox caps. | 1+ |
| P→A5-004 | A "bring-up race report" that records, per phase, which step was on the critical path; PR description auto-includes it so the next session knows where to attack next. | orchestration | Continuous improvement loop on cold-start time. | 1+ |
| P→A5-005 | Run the brainstorming-style fan-out pattern itself (this very session) as a reusable harness: `scripts/orchestrate/fanout.py <brief> <N>` spawns N subagents on a shared workspace. | subagent-pool | Generalizes what worked here so future brainstorms / reviews / audits are one command. | 0+ |

