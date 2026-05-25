# A1 — Debug & Observability Tools (Max Capability)

- Agent: A1
- Mandate: Brainstorm debug, observability, and CloudWatch tooling that exploits full AWS admin + direct kubectl + ArgoCD/Keycloak API + unlimited egress to answer "what is happening with X" in seconds across phases 0–6.
- Date: 2026-05-25
- Branch: claude/determined-pasteur-53fAN

| ID | Idea (one sentence) | Category | Justification | Applies to phase |
|---|---|---|---|---|
| A1-001 | `scripts/whereami.sh` one-shot that prints account ID, region, EKS name, zone, kubectl ctx, ArgoCD URL, Crossplane version. | debug-assist | First thing every session needs; replaces five separate `aws`/`kubectl` invocations. | 0+ |
| A1-002 | `scripts/phase-status.sh` that walks phases 0–6 and prints state (`not-coded` / `code-only` / `applied` / `verified`) by probing live resources, not the handoff. | debug-assist | Handoff state drifts; live probe is ground truth (per AGENTS.md §8.1). | 0+ |
| A1-003 | Enable EKS control-plane logging (api, audit, authenticator, controllerManager, scheduler) on cluster creation in `terraform/management/eks.tf`. | cloudwatch-setup | Authenticator/audit logs are the only way to debug IRSA & RBAC denials post-hoc. | 1+ |
| A1-004 | Enable VPC flow logs to CloudWatch in `terraform/base/vpc.tf` with a 7-day retention. | cloudwatch-setup | NAT/SG/route bugs are invisible without flow logs; cheap insurance. | 0+ |
| A1-005 | CloudTrail trail to a dedicated CloudWatch log group with 7-day retention. | cloudwatch-setup | Post-mortem any IAM/API failure with a single Logs Insights query. | 0+ |
| A1-006 | Logs Insights saved query: "AssumeRoleWithWebIdentity failures last 1h, grouped by role and SA subject". | logs-insights-query | This is the canonical IRSA-misconfig signature; recurring root cause. | 1+ |
| A1-007 | Logs Insights saved query: "EKS audit log denies grouped by user/group/verb last 1h". | logs-insights-query | RBAC misconfig diagnosis in 5 seconds. | 1+ |
| A1-008 | Logs Insights saved query: "Crossplane core reconcile errors filtered by XR name". | logs-insights-query | Replaces `kubectl logs ... | grep`; survives pod restarts. | 2+ |
| A1-009 | Logs Insights saved query: "ESO sync failures grouped by ExternalSecret name". | logs-insights-query | ESO failures are silent until consumer pod crashes. | 1+ |
| A1-010 | CloudWatch metric filter on EKS audit log for `system:anonymous` requests → alarm. | metric-filter | Detects misconfigured webhooks/ingress that bypass auth. | 1+ |
| A1-011 | CloudWatch metric filter on Crossplane core logs for `reconcile error` → counter metric per provider. | metric-filter | Quantifies churn; flips an alarm on sustained failure. | 2+ |
| A1-012 | CloudWatch alarm: NLB `UnHealthyHostCount > 0` for 2 min. | alarm | Ingress death is otherwise invisible until users complain. | 1+ |
| A1-013 | CloudWatch alarm: ASM `SecretRotationFailed` on any k8-platform/* secret. | alarm | Phase 2 PlatformSecret rotation should be observable. | 2+ |
| A1-014 | CloudWatch dashboard "k8-platform overview" with EKS node CPU/mem, NLB request rate, ArgoCD sync status (custom metric), Crossplane reconcile error rate. | dashboard | Single-pane glance; nobody opens 8 tabs in a hurry. | 1+ |
| A1-015 | CloudWatch dashboard "IRSA debug" with per-role AssumeRole success/failure counts. | dashboard | IRSA is the #1 bug class; dashboard surfaces it instantly. | 1+ |
| A1-016 | CloudWatch dashboard "Crossplane provisioning" with MR creation rate, XR Ready=True ratio, Composition function errors. | dashboard | Diagnose phase 2/3 silent-failure modes (XR with zero conditions). | 2+ |
| A1-017 | CloudWatch Container Insights enabled via CloudWatch agent DaemonSet IRSA role in `terraform/management/`. | cloudwatch-setup | Pod-level CPU/mem/disk/network for free. | 1+ |
| A1-018 | Python helper `scripts/irsa_trust_validator.py <role>` that fetches role trust, decodes OIDC provider, prints expected `sub` claim, lists matching SAs in cluster. | python-helper | Caught bug 5 (PR #66 SA-hash mismatch) in 10 seconds instead of 2 hours. | 1+ |
| A1-019 | `scripts/crossplane-trace.sh <claim>` that walks claim → XR → resourceRefs → MRs → underlying AWS object, printing `.status.conditions` at each layer. | runbook | One command answers "where is the chain broken". | 2+ |
| A1-020 | `scripts/argocd-app-poll.sh <app>` that hits ArgoCD API and waits until `Synced/Healthy` with a deadline. | wait-loop-helper | Replaces hand-rolled retry loops in integration scripts. | 1+ |
| A1-021 | `scripts/wait-for-claim.sh <kind> <name> [ns] [timeout]` that watches conditions and dumps composition events on timeout. | wait-loop-helper | Standardizes the most-repeated pattern in tests/integration. | 2+ |
| A1-022 | curl recipe: ArgoCD app sync via REST API with bearer token (one-liner). | curl-recipe | Faster than `argocd app sync` (no install); useful in workflows. | 1+ |
| A1-023 | curl recipe: Keycloak admin login → realm export → diff against repo source-of-truth. | curl-recipe | Detects manual drift in Keycloak realm config. | 5+ |
| A1-024 | curl recipe: Cognito hosted-UI smoke test (start auth flow, follow redirect, confirm 200). | curl-recipe | Auth-flow break is otherwise discovered by user. | 0+ |
| A1-025 | Terraform post-apply verifier that re-queries every IRSA role's trust and asserts the SA subject matches `irsa.tf`'s declared `namespace_service_accounts`. | terraform-postcheck | Bug 5 would have failed apply, not silently created broken roles. | 1+ |
| A1-026 | Terraform post-apply verifier that confirms every `helm_release` reports `STATUS: deployed` via the K8s API. | terraform-postcheck | `helm_release` resource can be "created" while pods CrashLoop. | 1+ |
| A1-027 | Terraform post-apply verifier that asserts every Crossplane Provider's `Healthy=True` and `Installed=True`. | terraform-postcheck | Caught the post-#68 hash-SA bug in the apply, not a subsequent claim. | 2+ |
| A1-028 | `scripts/eso-trace.sh <externalsecret> [ns]` that prints the chain: ExternalSecret → ClusterSecretStore → AWS ASM Secret → IRSA role → fetched value redaction. | runbook | ESO has 6 ways to fail; this collapses them. | 1+ |
| A1-029 | `scripts/kyverno-decision-explain.sh <resource>` that simulates Kyverno admission on a yaml and prints which policies pass/fail and why. | debug-assist | Phase 2 had ClusterPolicy 09 drift; this would have caught it. | 1+ |
| A1-030 | Auto-create a CloudWatch log group per ArgoCD app sync round via a controller, retention 7d. | cloudwatch-setup | Long-lived audit trail of GitOps actions; correlate with cluster events. | 1+ |
| A1-031 | `scripts/r53-watch.sh <name>` that polls Route53 record changes until propagation confirmed via authoritative dig. | wait-loop-helper | ExternalDNS races are the #2 ingress bug. | 1+ |
| A1-032 | `scripts/nlb-trace.sh` that walks Ingress → Service → NLB ARN → target group health → SG rules → reach test from a debug pod. | runbook | Six-hop debug collapsed into one command. | 1+ |
| A1-033 | A "krew-style" wrapper `kubectl k8p <subcmd>` (status, claim, secret, irsa, syncwave) that dispatches into our scripts. | debug-assist | Discoverable surface; lowers cognitive cost. | 1+ |
| A1-034 | `scripts/handoff-update.sh` that re-runs all live probes and rewrites the Environment State block in `ai/handoff.md`. | python-helper | AGENTS.md invariant #2 (always update handoff) automated. | 0+ |
| A1-035 | Pre-flight `scripts/quota-check.sh` that confirms current EC2 count + EIP + NAT + VPC against the sandbox limits before apply. | python-helper | Sandbox kill = account loss; this is cheap insurance. | 0+ |
| A1-036 | CloudWatch metric filter on CloudTrail for `RunInstances` events that would exceed sandbox 9-instance cap. | metric-filter | Alarm fires before account terminates. | 0+ |
| A1-037 | CloudWatch alarm on aggregate EC2 instance count > 7. | alarm | Two-instance margin against the 9-cap. | 0+ |
| A1-038 | `scripts/diff-state.sh phase=N` that compares `terraform plan` output to live cluster state and highlights drift. | terraform-postcheck | "Apply complete: 0 added" silent-no-op bug class (handoff §"It applied successfully ≠"). | 1+ |
| A1-039 | `scripts/crossplane-version-report.sh` that prints Crossplane core, every Provider, every Function, every DeploymentRuntimeConfig binding. | debug-assist | Version-skew bugs (v2.0.1 vs v2.2) are silent until they bite. | 2+ |
| A1-040 | Composition render dry-run helper that runs `crossplane render` locally against a claim + composition + function. | debug-assist | Catches composition function input rejections before cluster sees them. | 2+ |
| A1-041 | `scripts/keycloak-realm-diff.sh` that exports live realm and diffs against `clusters/.../keycloak/realm.json`. | runbook | Detects manual drift; AuthN bugs are the worst class to hunt. | 5+ |
| A1-042 | `scripts/cognito-user-create.sh` and `scripts/cognito-token-fetch.sh` helpers that exercise the user-pool with no AWS console clicks. | runbook | E2E auth tests need real tokens; this scripts them. | 0+ |
| A1-043 | `scripts/argocd-syncwave-view.sh <app>` that prints resources in sync-wave order with status. | debug-assist | Sync-wave bugs in phase 2a were painful; this surfaces order. | 2+ |
| A1-044 | CloudWatch Logs subscription filter that mirrors Kyverno PolicyReport failures to a dedicated log group. | cloudwatch-setup | Persistent record of policy violations; survives pod churn. | 1+ |
| A1-045 | `scripts/ebs-volume-list.sh` that lists volumes with size, attached node, age, against the 100 GB cap. | runbook | Prevents the silent cap-exceeded sandbox kill. | 1+ |
| A1-046 | `scripts/cert-watcher.sh` that polls ACM cert ARNs and asserts ISSUED + matches NLB listener. | wait-loop-helper | Cert mismatch breaks everything downstream; cheap to detect. | 0+ |
| A1-047 | `scripts/oidc-introspect.sh <jwt>` that decodes a pod-projected token's sub/aud/iss claims for IRSA debug. | debug-assist | Pairs with A1-018; both halves of IRSA mismatch. | 1+ |
| A1-048 | Run-bundle uploader `scripts/diag-bundle.sh` that tars cluster state (`kubectl get all -A`, events, CRDs, Crossplane providers, ArgoCD apps) into a timestamped tgz. | debug-assist | One-shot "send me everything"; replaces ad-hoc Slack triage. | 1+ |
| A1-049 | Per-XRD Chainsaw scenario that asserts `.status.conditions[*].type` contains all expected condition types within timeout. | debug-assist | Catches "XR has zero conditions" bug class explicitly. | 2+ |
| A1-050 | CloudWatch composite alarm: any of {NLB unhealthy, EKS node NotReady, IRSA failures>10/min, Crossplane reconcile errors>5/min}. | alarm | Single page-able signal for "platform is sick". | 1+ |
| A1-051 | `scripts/argocd-app-tree.sh <app>` rendering the parent → child Application tree with sync/health colored. | debug-assist | App-of-apps debugging needs a tree view. | 1+ |
| A1-052 | `scripts/eso-cluster-secret-store-validate.sh` that confirms CSS auth IRSA works by trying `aws secretsmanager list-secrets` from inside the ESO pod. | runbook | ESO failures are usually IRSA, but masked as "Secret not found". | 1+ |
| A1-053 | CloudWatch alarm on `aws_eks_cluster` API server 5xx rate > 1%. | alarm | API server health is otherwise invisible. | 1+ |
| A1-054 | Auto-tagging policy that adds `phase=N` and `managed-by=k8-platform` to every AWS resource for easy CloudTrail/billing filters. | cloudwatch-setup | Per-phase cost and audit attribution. | 0+ |
| A1-055 | `scripts/cost-report.sh` that uses Cost Explorer API to print this-month spend bucketed by phase tag. | python-helper | Sandbox has hidden cost caps too; visibility is cheap. | 0+ |
| A1-056 | `scripts/crossplane-reset-provider.sh <provider>` that deletes the Deployment + waits for Crossplane to re-render. | runbook | Codifies the PR #68 hack; one command instead of remembering steps. | 2+ |
| A1-057 | `kubectl events --watch` wrapper that filters to a single XR/claim and color-codes by type. | debug-assist | Tail-style debug; nicer than `kubectl get events`. | 2+ |
| A1-058 | Pre-commit hook that validates every YAML in `crossplane/`, `argocd/`, `clusters/`, `policies/` with `kubeconform` against the registered CRDs. | debug-assist | Catches Bug 4 (Composition string transform missing type) at author time. | 1+ |
| A1-059 | `scripts/jwks-check.sh <oidc-issuer>` that fetches issuer's JWKS and confirms it matches the IAM OIDC provider's thumbprint. | python-helper | OIDC issuer rotation is rare but silent-catastrophic. | 1+ |
| A1-060 | Synthetic canary: a Lambda or GH Action that hits ArgoCD `/healthz`, NLB `/`, Cognito `/.well-known/openid-configuration` every 5 min and posts to a CloudWatch metric. | cloudwatch-setup | First-derivative health signal independent of pods/nodes. | 1+ |
| A1-061 | Logs Insights saved query: "ExternalDNS Route53 API call errors last 1h grouped by record". | logs-insights-query | DNS bugs are slow; this is the fastest signal. | 1+ |
| A1-062 | Logs Insights saved query: "Crossplane composition function panics or timeouts". | logs-insights-query | Function pod crashes silently strand XRs. | 2+ |
| A1-063 | `scripts/keycloak-token-roundtrip.sh` that performs full OIDC dance against Keycloak and asserts ID-token group claim equals expected. | runbook | EKS-via-Keycloak (REQ-AUTH-07..10) needs this as health check. | 5+ |
| A1-064 | `scripts/probe-workload-cluster.sh <cluster>` that walks ClusterRoleBinding → kc:group → Cognito group membership end-to-end. | runbook | Phase 5/6 access debugging. | 5+ |
| A1-065 | `scripts/oom-report.sh` that lists pods with restart count > 0 + reason from container status. | debug-assist | OOMs masquerade as flakes; this surfaces the pattern. | 1+ |
| A1-066 | CloudWatch alarm on EBS volume `BurstBalance < 20%` (only relevant on gp2). | alarm | Disk throttling explains slow apiserver behavior. | 1+ |
| A1-067 | `scripts/sg-explain.sh <sg>` that prints inbound/outbound rules grouped, with referenced SG names resolved. | debug-assist | SG debug is the worst kind without this. | 0+ |
| A1-068 | `scripts/sts-decode.sh` that prints the current caller's effective permissions via IAM simulator API. | python-helper | "Why does this fail?" answered without console clicks. | 0+ |
| A1-069 | A unified `scripts/diag.sh` dispatcher: `diag.sh irsa|eso|argocd|crossplane|nlb|cert|cognito|kyverno|all` invoking the right specialist. | debug-assist | Memorize one command, not nine. | 1+ |
| A1-070 | `scripts/cleanup-orphans.sh` that lists AWS resources tagged `managed-by=k8-platform` but not referenced by terraform state or any Crossplane XR. | runbook | Sandbox kill class: drifted resources past the cap. | 0+ |

## Cross-review additions

Additive, collaborative extensions from every other agent and the primary orchestrator. No criticism — only amplifications, related ideas, pairings, and meta-observations.

### from A2

| ID | Idea | Category | Justification | Applies to phase |
|---|---|---|---|---|
| A2→A1-001 | Turn `scripts/whereami.sh` (A1-001) into a JSON-emitting mode so e2e tests can assert account/region/cluster fixtures match `terraform.tfvars` before running. | test-oracle-promotion | Reusing a debug script as a precondition gate prevents tests from running against the wrong sandbox. | 0+ |
| A2→A1-002 | Promote `phase-status.sh` (A1-002) to a chainsaw `assert:` oracle that verifies each phase's `verified` state inside a smoke test. | test-oracle-promotion | Live-probe truth becomes an automated regression guard, not just a human aid. | 1+ |
| A2→A1-003 | Add an integration test that, after enabling EKS control-plane logging (A1-003), writes a synthetic `system:anonymous` request and asserts the audit log group receives the line within 60s. | smoke-test | Proves the logging pipeline actually emits, not just that the cluster claims it's enabled. | 1+ |
| A2→A1-004 | E2E pairing for A1-018 (`irsa_trust_validator.py`): run it across every IRSA role in CI and fail the build on any mismatch — making the debug tool the oracle for A2-005/A2-006. | test-oracle-promotion | One script, two jobs: human triage and CI invariant. | 1+ |
| A2→A1-005 | Wrap `crossplane-trace.sh` (A1-019) output as a chainsaw `error:` block — when an assert fails, the trace dumps automatically. | test-oracle-promotion | Failure evidence is structured at no extra cost. | 2+ |
| A2→A1-006 | Use `wait-for-claim.sh` (A1-021) as the canonical wait primitive in every A2 soak/concurrency test (A2-016, A2-017, A2-050). | test-oracle-promotion | One bug surface for wait semantics across the test suite. | 2+ |
| A2→A1-007 | Add an e2e test that runs `keycloak-realm-diff.sh` (A1-041) nightly and posts diff to a slack channel — drift becomes a tracked event. | smoke-test | Operationalizes drift detection. | 5+ |
| A2→A1-008 | Add an integration test that fires the CloudWatch composite alarm (A1-050) via synthetic metric injection to prove the page-able path works. | smoke-test | Untested alarms are decoration; this proves the wiring. | 1+ |
| A2→A1-009 | Use `cognito-token-fetch.sh` (A1-042) as the credential source for A2-009/A2-010 OIDC e2e tests. | test-oracle-promotion | Removes hand-rolled OIDC dance from each test. | 0+ |
| A2→A1-010 | Add a contract test that every saved Logs Insights query (A1-006..A1-009, A1-061..A1-062) parses and returns ≤1 row when run against a known-good fixture stream. | smoke-test | Saved queries rot silently when log shapes change; a regression test pins them. | 1+ |
| A2→A1-011 | Promote `eso-trace.sh` (A1-028) and `eso-cluster-secret-store-validate.sh` (A1-052) into the A2-023 ESO chaos test as the in-band oracle. | test-oracle-promotion | Same debugging logic surfaces failures both interactively and in CI. | 1+ |
| A2→A1-012 | Add an e2e canary harness on top of A1-060 that runs A2-049 (Cognito hosted-UI Selenium) every 15 min and feeds a synthetic-metric CloudWatch alarm. | smoke-test | Browser-level auth flow becomes an SLO. | 1+ |
| A2→A1-013 | Use `diag-bundle.sh` (A1-048) as the on-failure artifact for every A2 chaos test — uploaded automatically to the run. | test-oracle-promotion | One bundle format means one post-mortem workflow. | 1+ |
| A2→A1-014 | Add a regression test that the terraform post-apply verifiers (A1-025/026/027) actually fail when fed a broken fixture — meta-test the verifier. | smoke-test | Verifier-without-tests is just faith. | 1+ |
| A2→A1-015 | Pair `oidc-introspect.sh` (A1-047) with A2-004 to compare projected-token claims to IAM role expectations inside the assertion. | test-oracle-promotion | Closes the loop on both halves of IRSA mismatch into a single oracle. | 1+ |

### from A3

| ID | Idea | Category | Justification | Applies to phase |
|---|---|---|---|---|
| A3→A1-001 | Extend A1-002 `phase-status.sh` to also emit a JSON manifest a regression test can diff against the previous run, turning live probes into a drift oracle. | regression-extension | Doubles the debug tool as a recurring test artifact; would have surfaced Bug 3 (Kyverno drift) on cadence. | 0+ |
| A3→A1-002 | Pair A1-018 IRSA trust validator with a CI mode that exits non-zero so it can run as a pre-merge gate, not only an interactive helper. | regression-extension | Bug 5 (PR #66) recurred because no gate enforced the trust=SA invariant. | 1+ |
| A3→A1-003 | Add a "snapshot mode" to A1-019 `crossplane-trace.sh` that writes condition snapshots to disk so two consecutive runs can diff XR/MR state over time. | regression-extension | Catches "XR went silent" between reconciles; would have flagged the v2.0.1 zero-conditions bug. | 2+ |
| A3→A1-004 | Extend A1-025 (TF post-apply IRSA verifier) to also verify the SA actually exists in cluster, not just that subjects parse — catches the SA-rename half of Bug 5. | regression-extension | Trust JSON can be syntactically valid while pointing at a deleted SA. | 1+ |
| A3→A1-005 | A1-029 Kyverno explain helper could keep a golden corpus of "expected-pass" and "expected-fail" YAMLs so it doubles as a regression suite for policy refactors. | regression-extension | Policy 09 drift recurred; corpus-based regression locks behavior. | 1+ |
| A3→A1-006 | Have A1-038 `diff-state.sh` write its drift report to a CloudWatch log group so any drift over time is auditable across sessions. | regression-extension | Cross-session drift is currently invisible between handoffs. | 1+ |
| A3→A1-007 | A1-040 composition render dry-run helper should support a fixture directory so every Composition has an expected rendered output checked into git. | regression-extension | Locks in Bug 4 (string transform `type: Format`) as a permanent guard. | 2+ |
| A3→A1-008 | Extend A1-058 pre-commit kubeconform hook to also verify Compositions against the function input schema, not only against the XRD. | regression-extension | Function-input-schema mismatches are a distinct silent-failure class. | 2+ |
| A3→A1-009 | Add a "self-test" mode to A1-060 synthetic canary that intentionally injects a known-bad URL and asserts the metric goes red within deadline. | regression-extension | Validates the alarming pipeline itself (alarm-on-alarm-system). | 1+ |
| A3→A1-010 | Pair A1-027 (Crossplane Provider healthy verifier) with a record of the provider image digest so silent image-pin rollbacks are caught. | regression-extension | Provider re-tag silently breaks Compositions; digest pin is the canonical guard. | 2+ |
| A3→A1-011 | A1-070 orphan-cleanup script could emit a baseline expected-resource manifest per phase; deviations become a test failure not just a "list". | regression-extension | Codifies sandbox-cap invariant against silent leaks. | 0+ |
| A3→A1-012 | Extend A1-048 diag bundle to include `terraform state pull` snapshot — completes the "send me everything" picture and supports apply-vs-state diff offline. | regression-extension | The "Apply complete: 0 added" silent-no-op class is invisible without state. | 1+ |
| A3→A1-013 | A1-049 per-XRD chainsaw scenario should be templated from XRD source so adding a new XRD auto-generates the condition-coverage test. | regression-extension | Prevents future XRDs from shipping without condition assertions. | 2+ |

### from A4

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

### from A5

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

### from A6

| ID | Idea | Category | Justification | Applies to phase |
|---|---|---|---|---|
| A6→A1-001 | Once `scripts/whereami.sh` (A1-001) lands, retire the per-script preambles that re-echo account/region/cluster in every diag tool. | refactor | Single source; preamble noise vanishes. | 0+ |
| A6→A1-002 | When `scripts/phase-status.sh` (A1-002) is the oracle, delete the Environment State table in `ai/handoff.md` in favor of a generated include. | simplification | Removes the drift class A1-002 was built to eliminate. | 0+ |
| A6→A1-003 | EKS control-plane logging (A1-003) lets us delete every workflow-side "kubectl get events | grep RBAC" workaround in `tests/integration/`. | refactor | Audit log is durable; pod-side scraping was a hack. | 1+ |
| A6→A1-004 | Logs Insights saved queries (A1-006..A1-009) supersede the bash-grep helpers in `scripts/diag-component.sh`; retire those subcommands. | simplification | One query language, not two. | 1+ |
| A6→A1-005 | Terraform post-apply verifiers (A1-025..A1-027) make the standalone `tests/integration/05_irsa_*.sh` redundant once apply itself fails. | refactor | Shift-left; one gate not two. | 1+ |
| A6→A1-006 | `scripts/crossplane-trace.sh` (A1-019) lets us delete `phase-2-diagnose.yml` entirely — the dispatch workflow exists only because no local trace did. | simplification | Removes a 250-line workflow yaml. | 2+ |
| A6→A1-007 | `scripts/wait-for-claim.sh` (A1-021) replaces every bespoke `until kubectl get ...; do sleep` loop in tests/integration/*.sh. | refactor | Codifies one helper; deletes ~10 copy-pastes. | 2+ |
| A6→A1-008 | Auto-tagging policy (A1-054) lets us retire the per-resource "Name = k8-platform-<x>" naming hacks used as a poor-man's tag. | simplification | Tags are queryable; name-prefix is not. | 0+ |
| A6→A1-009 | `scripts/diag.sh` dispatcher (A1-069) lets us delete the now-redundant top-level wrappers `kyverno-violations.sh`, `route53-records.sh`, `diag-component.sh`. | refactor | One entrypoint replaces nine. | 1+ |
| A6→A1-010 | `scripts/cleanup-orphans.sh` (A1-070) plus auto-tagging (A1-054) lets us drop the manual "remember to delete X" notes scattered across retros. | simplification | Tool replaces tribal knowledge. | 0+ |
| A6→A1-011 | The `kubectl k8p` krew-style wrapper (A1-033) supersedes the README "common commands" section — make the wrapper self-documenting. | simplification | One source of truth for the surface. | 1+ |
| A6→A1-012 | The handoff-update script (A1-034) lets us retire the manual "Environment State" maintenance ritual described in AGENTS.md invariant #2. | simplification | The rule survives; the manual labor doesn't. | 0+ |

### from PRIMARY

| ID | Idea | Category | Justification | Applies to phase |
|---|---|---|---|---|
| P→A1-001 | A single `inspect <resource>` shell wrapper that auto-dispatches (claim → XR → MR → IRSA → cloud) based on `kind` so the agent types one verb regardless of what's broken. | shell-helper | Eliminates the "which command do I run for this kind?" cognitive tax that recurs every debug loop. | 1+ |
| P→A1-002 | A `make doctor` target that runs every cheap read-only health probe (caller-id, kubeconfig age, ArgoCD reachable, CRDs present, provider Healthy, IRSA SA-name pinned) and emits a one-screen status board. | runbook | Cheap pre-flight that catches "stale kubeconfig" / "rotated account" before they cost a debug loop. | 0+ |
| P→A1-003 | Auto-create a CloudWatch Logs log group `/k8-platform/agent-session/$DATE` and tee every `aws`/`kubectl` invocation into it for postmortem replay. | cloudwatch-setup | Makes "what did the agent actually do?" answerable after the sandbox is torn down. | 0+ |
| P→A1-004 | A `dashboards/` folder of one JSON per dashboard (EKS, Crossplane, ESO, ArgoCD, ExternalDNS, Kyverno, Cognito) that Terraform applies idempotently on every phase-1 apply. | dashboard | Re-bootstrappable across account rotations; zero clicks to get to "what's going on right now". | 1+ |
| P→A1-005 | A "diagnose digest" Python script that pulls the last hour from all relevant log groups + last 50 events from all crossplane-system pods + all MR statuses into a single ~5 KB digest the agent can paste back into context. | python-helper | Shrinks 170 KB diagnose logs into agent-readable evidence; closes the "context overflow" failure mode from the old diagnose workflows. | 1+ |
| P→A1-006 | Annotate every Terraform-managed resource with `tags = { k8platform-phase = "0"|"1"|"2", k8platform-component = "..." }` so CloudWatch / cost / drift queries can filter by phase. | terraform-postcheck | Lets dashboards/alarms scope to the phase being worked on without recomputing arn lists. | 0+ |
| P→A1-007 | A `wait-for` polyglot CLI (`wait-for claim/X ready`, `wait-for mr/Y synced`, `wait-for argo-app/Z healthy`, `wait-for irsa/<role> assumable`) — one tool, many backends. | wait-loop-helper | Replaces ad-hoc `until` loops scattered across runbooks. | 1+ |

