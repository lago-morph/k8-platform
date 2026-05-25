# A2 — Integration & E2E Tests (Max Capability)

- Agent: A2
- Mandate: Brainstorm integration / E2E / chaos / soak / negative / concurrency / contract tests that become trivial now that the agent has full AWS admin, direct kubectl, ArgoCD/Keycloak admin APIs, unlimited egress, and CloudWatch SDK access.
- Date: 2026-05-25
- Branch: claude/determined-pasteur-53fAN

| ID | Idea (one sentence) | Category | Justification | Applies to phase |
|---|---|---|---|---|
| A2-001 | End-to-end PlatformSecret claim round-trip that creates the claim, waits Ready, then uses the AWS Secrets Manager SDK to read the resulting ASM secret and assert tags/KMS/replication match the Composition. | claim-roundtrip-test | The composition can render a "Ready" MR while the actual ASM Secret has wrong tags/region/KMS — only an SDK readback proves the cloud truth. | 2+ |
| A2-002 | Same PlatformSecret round-trip but probe the cloud truth from a DIFFERENT region's STS+SecretsManager client to catch global vs regional endpoint bugs. | claim-roundtrip-test | Region-specific Composition bugs (wrong provider region override) silently pass single-region tests. | 2+ |
| A2-003 | IRSA correctness test that, for every IRSA role in `terraform/management/irsa.tf`, calls `aws iam simulate-principal-policy` with the exact actions the SA's pods need and asserts allowed. | irsa-test | Permissions drift is invisible until a claim fails in production — simulate-principal catches it pre-flight. | 1+ |
| A2-004 | IRSA live-token test that runs `aws sts assume-role-with-web-identity` using a freshly projected SA token from each platform SA, confirming trust+permissions at the token level. | irsa-test | The cluster<->IAM federation can break in five places; only a live AssumeRole proves the chain works. | 1+ |
| A2-005 | Cross-resource invariant test: every IRSA role's trust `sub` must match a SA actually present in the live cluster (catches stale role drift). | irsa-test | The PR #66 SA-hash bug went undetected because no test compared trust-subject to live SA list. | 1+ |
| A2-006 | Inverse invariant test: every platform SA with `eks.amazonaws.com/role-arn` annotation must point at an IRSA role whose trust list contains its (namespace, name). | irsa-test | Catches the opposite drift — SA annotation rewritten to a deleted role. | 1+ |
| A2-007 | ArgoCD admin-API drift test that diffs every Application's live manifest hash against git HEAD and fails on any unexpected drift. | e2e-test | ArgoCD self-heal can silently flap; an out-of-band diff is the only honest oracle. | 1+ |
| A2-008 | ArgoCD admin-API forced-sync test that triggers `POST /api/v1/applications/<name>/sync` for every app and asserts `Synced/Healthy` within deadline. | e2e-test | Tests that ArgoCD can recover from arbitrary out-of-sync state, not just steady state. | 1+ |
| A2-009 | Keycloak admin-API realm-lifecycle test that creates a temp realm, adds a client, adds a user, performs an OIDC password flow, then deletes the realm. | oidc-flow-test | Real Keycloak realm CRUD is impossible from GH Actions but trivial now; covers REQ-AUTH-07..10. | 5+ |
| A2-010 | Real OIDC authorization-code flow against Keycloak using `requests` + a headless redirect handler, asserting an ID token with `groups` claim. | oidc-flow-test | The only test that proves the federation chain Cognito->Keycloak->client works end-to-end. | 5+ |
| A2-011 | kubectl-as-Keycloak-user test that exchanges a Keycloak token via `oidc-login` and verifies the EKS API server accepts it with the expected `kc:` group prefix. | oidc-flow-test | This is the entire point of phase 5; nothing else proves the EKS OIDC client config works. | 5+ |
| A2-012 | CloudWatch Logs Insights query as oracle: after applying a claim, query Crossplane logs for the XR name and assert zero `reconcile error` rows. | integration-test | Cluster-side `kubectl logs` is racy with pod restarts; CloudWatch is durable. | 2+ |
| A2-013 | CloudWatch Logs Insights query as oracle: after an OIDC flow, query EKS audit log for the user's first `get pods` and assert `system:authenticated`. | integration-test | Verifies the cluster *accepted* the OIDC user, not just that Keycloak issued the token. | 5+ |
| A2-014 | Negative test: delete an IRSA role mid-claim-provisioning and assert Crossplane MR enters a clean failed state with a useful error condition. | negative-test | Real recovery semantics matter; silent reconciliation loops are worse than failures. | 2+ |
| A2-015 | Recovery test: re-create the IRSA role from A2-014 and assert the claim returns to Ready=True without manual intervention. | negative-test | Self-healing is a documented contract; only a chaos+recovery test proves it. | 2+ |
| A2-016 | Concurrency test: kubectl-apply 20 PlatformSecret claims in parallel across 5 namespaces and assert all reach Ready within deadline with no UID collisions on ASM names. | concurrency-test | The Composition uses `<XR-uid>` to avoid collisions — only fan-out testing exercises the collision path. | 2+ |
| A2-017 | Concurrency test: 10 simultaneous PlatformCluster claims to confirm EKS module idempotency and IRSA-provider rate-limit handling. | concurrency-test | Phase 3 EKS-via-XRD will hit AWS API throttling under fan-out; better to catch in test. | 3+ |
| A2-018 | Soak test: a single PlatformSecret left running for 60 minutes with `refreshInterval: 30s` while a sidecar verifies every refresh against ASM SDK. | soak-test | Catches token-expiry, ESO re-auth, and IRSA-token-renewal bugs that only surface after the 1h SA token TTL. | 2+ |
| A2-019 | Soak test: long-running ArgoCD Application sync stability over 90 minutes asserting zero spurious OutOfSync transitions. | soak-test | Phase-2 had perennial OutOfSync from Kyverno drift (Bug 3); a soak catches the next instance instantly. | 1+ |
| A2-020 | ExternalDNS round-trip test that creates an Ingress, polls `dig @ns-<...>.awsdns-<...>.com` until propagation, then HTTPS-GETs the URL. | e2e-test | Public-recursor DNS lies for minutes; authoritative dig is the only honest oracle (per `scripts/route53-records.sh` lesson). | 1+ |
| A2-021 | ExternalDNS deletion-cleanup test that deletes the Ingress and asserts the Route53 record disappears within the propagation window. | e2e-test | Stale DNS records are the #2 cleanup leak; only an SDK probe catches them. | 1+ |
| A2-022 | Chaos test: kill the Crossplane controller pod mid-reconcile and assert no managed resource is left in `<no-status>` purgatory. | chaos-test | The v2.0.1 composite-reconciler bug observed in handoff Step 7 looks exactly like a kill-mid-reconcile failure mode. | 2+ |
| A2-023 | Chaos test: kill the ESO controller pod during a secret rotation and assert no Secret is left with stale value. | chaos-test | ESO failure modes are silent until consumers read the wrong value. | 1+ |
| A2-024 | Chaos test: scale ingress-nginx to zero, assert NLB UnHealthyHostCount alarms, scale back, assert recovery. | chaos-test | Verifies the alarming path A1-012 actually fires. | 1+ |
| A2-025 | Chaos test: revoke the management cluster's OIDC provider in IAM and assert every IRSA-dependent controller surfaces an actionable error within 5 minutes. | chaos-test | OIDC provider misconfig is catastrophic and silent; chaos test proves observability fires. | 1+ |
| A2-026 | Negative test: apply a PlatformSecret claim with a schema-violating extra field and assert kubectl-apply fails with a clear strict-schema error. | negative-test | XRD strict-schema gate (followup #6) needs an actual rejection oracle. | 2+ |
| A2-027 | Negative test: apply a PlatformSecret claim in a namespace not on the Kyverno allowlist and assert the audit policy emits a violation report. | negative-test | Kyverno audit-mode failures are visible only by query; needs an explicit test. | 2+ |
| A2-028 | Contract test: every Composition's `resourceRefs` schema must match the live MR types installed by the provider-family-aws CRDs. | contract-test | Composition drift vs CRD versions silently breaks XRs (looks like the v2.0 zero-conditions bug). | 2+ |
| A2-029 | Contract test: every XRD `claimNames` listed in `crossplane/xrds/` must have a matching Kyverno policy in `policies/audit/` if cross-namespace concerns apply. | contract-test | Pairs XRDs with their guardrails so a new XRD without policy is caught at PR time. | 2+ |
| A2-030 | Contract test: every ArgoCD Application's `repoURL` must point at the same monorepo, not a forked branch. | contract-test | Bootstrap-from-fork is a class of incident the agent has hit before. | 1+ |
| A2-031 | Contract test: every `helm_release` chart version in `terraform/management/variables.tf` must match the version pinned in `tests/chainsaw/run.sh`. | contract-test | The chainsaw harness silently drifted from prod versions in past sessions; lint freezes them in lockstep. | 1+ |
| A2-032 | Cross-resource invariant: every ClusterSecretStore must reference an IRSA SA whose role grants `secretsmanager:GetSecretValue` on the queried ASM path. | contract-test | ESO config error surfaces only when a consumer reads — invariant catches it pre-flight. | 1+ |
| A2-033 | Cross-resource invariant: every Crossplane Composition writing to a region must match the provider's configured region or use explicit region override. | contract-test | Cross-region Composition bugs are notoriously silent (followup #4). | 2+ |
| A2-034 | E2E test: full claim->XR->MR->ASM Secret->ExternalSecret->K8s Secret round-trip including reading the K8s Secret payload and comparing to the SDK-read ASM value. | e2e-test | Six-stage chain has many possible silent failures; only end-to-end byte-compare proves correctness. | 2+ |
| A2-035 | Concurrency+chaos hybrid: 10 claims in parallel while bouncing the Crossplane controller every 30s; all must reach Ready. | chaos-test | Stresses leader-election and work-queue ordering under realistic conditions. | 2+ |
| A2-036 | Negative test: create an Ingress with a TLS host outside the wildcard ACM cert SAN and assert ALB attachment fails with diagnosable error. | negative-test | Hostname/cert mismatch is a recurring confusing failure; explicit test makes the error class loud. | 1+ |
| A2-037 | OIDC flow test: revoke a Keycloak user's group membership and assert the next EKS API call fails with `forbidden` (proves group-claim freshness, not just token validity). | oidc-flow-test | Token caching masks revocations; needs a test of the no-cache path. | 5+ |
| A2-038 | OIDC flow test: rotate the Keycloak realm signing key and assert in-flight kubectl sessions either succeed via JWKS refresh or fail cleanly. | oidc-flow-test | Key rotation procedures are theoretical until tested. | 5+ |
| A2-039 | Concurrency test: 50 OIDC token requests against Keycloak in parallel asserting all succeed within deadline (proves Keycloak HA / DB connection pool). | concurrency-test | Keycloak is a single-pod SPOF until proven otherwise. | 5+ |
| A2-040 | Soak test: keep a kubectl `watch pods` open for 60 minutes via the Keycloak-federated OIDC user, asserting the token refresh path works. | soak-test | Token expiry mid-watch is a recurring kubectl surprise. | 5+ |
| A2-041 | Integration test: dispatch an ArgoCD ApplicationSet, wait for fan-out, then delete and assert no orphan Applications. | integration-test | ApplicationSet cleanup bugs are subtle. | 3+ |
| A2-042 | CloudWatch oracle test: assert that within 5 min of any `terraform apply` the CloudTrail log contains an `eks:UpdateClusterConfig` (or equivalent) that ties the apply to a specific principal. | integration-test | Provides an auditable chain of custody for every apply. | 0+ |
| A2-043 | Negative test: attempt to deploy a Pod with `hostNetwork: true` and assert Kyverno enforce-mode (when enabled) rejects it. | negative-test | Validates the upgrade path from audit-mode to enforce-mode is real. | 1+ |
| A2-044 | E2E test: provision a PlatformCluster claim, then run `aws eks describe-cluster` and assert version, addons, IRSA OIDC provider, and node group match the Composition. | claim-roundtrip-test | EKS-via-XRD is phase 3's biggest contract; SDK readback is the only oracle. | 3+ |
| A2-045 | E2E test: from the management cluster, kubectl against the spoke EKS provisioned by A2-044 using the bootstrap admin to confirm reachability. | e2e-test | Cluster Ready != cluster reachable; explicit kubectl probe needed. | 3+ |
| A2-046 | Negative test: tear down a spoke PlatformCluster claim and assert all spoke-side AWS resources (NodeGroup, OIDC provider, ENIs, security groups, EBS volumes) are gone via SDK enumeration. | negative-test | Crossplane delete-cascade has known orphan classes; enumeration is the only oracle. | 3+ |
| A2-047 | Concurrency test: two ArgoCD sync operations against the same App from two clients to confirm idempotent serialization. | concurrency-test | Race-condition syncs can leave the App in an oscillating state. | 1+ |
| A2-048 | Chaos test: cordon both nodes simultaneously, assert PDBs prevent total outage, uncordon, assert auto-recovery. | chaos-test | The 2-node cap (sandbox limit) makes PDB testing nontrivial but important. | 1+ |
| A2-049 | E2E test: trigger Cognito hosted-UI login programmatically (Selenium or requests-with-cookie-jar), complete the flow, assert a session JWT. | e2e-test | Cognito UI breaks silently when SPA config drifts; only browser-flow tests catch it. | 0+ |
| A2-050 | Soak test: every 5 min for 2 hours, dispatch a probe PlatformSecret claim, measure time-to-Ready, fail if any iteration exceeds 90s baseline by 3x. | soak-test | Latency creep is invisible until it becomes outage; baseline + threshold catches it. | 2+ |
| A2-051 | Negative test: revoke the ArgoCD admin password and assert subsequent CLI sync fails with auth error rather than silent no-op. | negative-test | Authentication-failure-as-success is a known anti-pattern. | 1+ |
| A2-052 | Contract test: every ExternalSecret must reference a ClusterSecretStore that actually exists in the cluster. | contract-test | Dangling refs render silently in `kubectl get` but never sync. | 1+ |
| A2-053 | Integration test: rotate an ASM secret value via SDK, wait `refreshInterval`+10s, read the downstream K8s Secret and assert the new value propagated. | integration-test | Phase 2's whole value proposition is rotation; needs an end-to-end oracle. | 2+ |
| A2-054 | Concurrency test: create a PlatformSecret claim while simultaneously deleting it (within 1s), assert no orphan ASM Secret remains. | concurrency-test | Create-delete race exposes finalizer ordering bugs. | 2+ |
| A2-055 | OIDC flow test: assume a Keycloak break-glass admin path via realm-export-import to verify disaster recovery procedure works. | oidc-flow-test | DR procedures rot in docs until tested. | 5+ |
| A2-056 | CloudWatch metric-filter regression test: emit a known synthetic log line and assert the metric increments within 60s. | integration-test | Validates the alerting pipeline itself, not just that alarms are configured. | 4+ |
| A2-057 | Chaos test: induce ECR pull throttling (rapid-pull loop) and assert pod restart back-off survives without crashing the cluster. | chaos-test | Real-world failure mode that's hard to reproduce except by deliberate induction. | 1+ |
| A2-058 | Negative test: apply a Composition with a `type: Format` missing on a string transform (the PR #61 bug) and assert chainsaw fails fast with a meaningful error. | negative-test | Codifies bug 4 as a permanent guard. | 2+ |
| A2-059 | Soak test: 4-hour ArgoCD self-heal loop with a deliberately mutated resource every 10 min, asserting reversion every cycle without leak. | soak-test | Self-heal feedback loops can degrade slowly; soak surfaces it. | 1+ |
| A2-060 | E2E test: from a workload cluster (phase 6), call the management cluster's ArgoCD admin API to register itself and assert appearance in `argocd cluster list`. | e2e-test | Multi-cluster registration is phase 6's central contract. | 6+ |
| A2-061 | Concurrency test: scale a Deployment from 1 to 50 replicas and back to 1, assert ExternalDNS doesn't thrash records. | concurrency-test | Rapid endpoint churn historically broke ExternalDNS. | 1+ |
| A2-062 | Chaos test: simulate AWS regional API failure by deny-listing the SecretsManager endpoint via NetworkPolicy and assert ESO surfaces error within 2 min. | chaos-test | Network-level failure injection is impossible without cluster-admin. | 1+ |
| A2-063 | Negative test: deploy two Ingresses with identical host, assert only one wins and the other reports a clear conflict status. | negative-test | Silent overwrite is a known ingress-nginx footgun. | 1+ |
| A2-064 | E2E test: dispatch `terraform destroy` for phase 2 only and assert phase 1 helm releases remain Healthy (AGENTS.md §5 invariant 1). | e2e-test | Invariant 1 is load-bearing and currently unenforced by any test. | 2+ |
| A2-065 | Contract test: every CloudWatch log group referenced in saved Logs Insights queries (A1-006..A1-009) actually exists post-apply. | contract-test | Dangling query targets render silently empty results. | 1+ |

## Cross-review additions

Additive, collaborative extensions from every other agent and the primary orchestrator. No criticism — only amplifications, related ideas, pairings, and meta-observations.

### from A1

| ID | Idea | Category | Justification | Applies to phase |
|---|---|---|---|---|
| A1→A2-001 | Pair every claim-roundtrip (A2-001/044) with an automatic CloudTrail cross-check that asserts the exact AWS principal + IRSA role chain that performed the write, captured by event-name. | observability-pair | Proves *who* did the write, not just that the write happened — catches privilege drift. | 2+ |
| A1→A2-002 | Extend A2-003 (simulate-principal) to also dump the resolved effective policy JSON per role into an artifact so future debugging has a baseline diff. | observability-extension | Snapshot becomes a regression oracle for IAM policy drift. | 1+ |
| A1→A2-003 | Pair A2-007 (ArgoCD drift diff) with a Kyverno PolicyReport snapshot so drift attributable to admission mutation is auto-classified vs human edits. | classification-extension | Bug 3 root-cause classification becomes one-shot. | 1+ |
| A1→A2-004 | Extend A2-012 / A2-013 (CloudWatch oracles) with a saved Logs Insights query library committed to the repo (`observability/queries/*.yml`) callable by test-name. | observability-extension | Codifies oracle queries so tests share, version, and review them. | 2+ |
| A1→A2-005 | Pair chaos kills (A2-022/023) with an EBPF/`crictl` capture of the dying pod's last 30s of syscalls via a sidecar DaemonSet for richer post-mortem. | chaos-extension | Goes beyond logs to syscall-level evidence when controllers die mid-reconcile. | 2+ |
| A1→A2-006 | Extend A2-016 (concurrent claims) with an X-Ray-style trace ID injected per claim via XR annotation, then assert end-to-end propagation through CloudWatch logs. | tracing-extension | Distributed-tracing of XR pipelines turns concurrency debugging from log-grep to span-view. | 2+ |
| A1→A2-007 | Pair A2-020 (ExternalDNS round-trip) with a Route53 query-log capture (enable on the hosted zone) and assert the test's resolver IP appears, proving the propagation path. | observability-pair | Distinguishes "DNS not propagated" from "resolver cached NXDOMAIN". | 1+ |
| A1→A2-008 | Extend A2-025 (OIDC provider revoke chaos) with a baseline CloudWatch alarm assertion that the platform's `IRSAFailureCount` metric crosses threshold within SLO. | observability-extension | Validates not just the failure mode but the alerting SLO. | 1+ |
| A1→A2-009 | Add a contract test that every test in this file produces a structured JSON result artifact in a shared schema, enabling cross-run trend analytics. | meta-test | Lets you ask "which test got 30% slower this month?" — impossible without structured artifacts. | 0+ |
| A1→A2-010 | Pair A2-053 (rotation propagation) with an ASM rotation-Lambda invocation count metric to detect double-rotation races. | observability-pair | Rotation race conditions are silent until two consumers disagree. | 2+ |
| A1→A2-011 | Extend A2-018/050 (soak tests) with continuous Prometheus scraping of controller workqueue depth + reconcile latency p99, asserting no monotonic drift. | observability-extension | Memory leaks and queue creep show in workqueue metrics hours before pod OOMs. | 2+ |
| A1→A2-012 | Pair A2-046 (PlatformCluster teardown enumeration) with AWS Config history queries so the SDK enumeration sees *deleted* resources, not just missing ones (Config retains tombstones). | observability-pair | Distinguishes "deleted cleanly" from "never created" — critical for cleanup tests. | 3+ |
| A1→A2-013 | Add a per-test "evidence pack" assertion: every failing test must auto-attach (cluster events ±5 min, controller logs, CloudTrail ±5 min, Prom snapshot) before exiting non-zero. | meta-test | Eliminates the "rerun to gather evidence" loop. | 1+ |
| A1→A2-014 | Pair A2-049 (Cognito hosted-UI flow) with a CloudTrail `Authentication` event query asserting the same flow appears server-side. | observability-pair | Catches client-side mocks pretending to be a real flow. | 0+ |
| A1→A2-015 | Extend A2-060 (multi-cluster registration) with a Route53 health-check probe from each cluster to the mgmt ArgoCD endpoint, asserting bidirectional reachability. | observability-extension | Registration appearing != reachable; reachability is the actual contract. | 6+ |

### from A3

| ID | Idea | Category | Justification | Applies to phase |
|---|---|---|---|---|
| A3→A2-001 | Add a Bug-5 regression scenario to A2-005 (trust=SA invariant): rename a platform SA in a fixture and assert the invariant test fails loudly. | regression-extension | Locks PR #66 as a permanent guard rather than an emergent property. | 1+ |
| A3→A2-002 | Pair A2-016 (20 parallel PlatformSecret claims) with a CloudWatch oracle that asserts no Crossplane `reconcile error` spike during the burst. | regression-extension | Catches throttling-induced silent retries that don't surface in claim status. | 2+ |
| A3→A2-003 | Extend A2-022 chaos test to also kill the composition function pod, not just the core controller — separate failure surface. | regression-extension | Bug 4-class composition-function input rejections look like controller bugs but aren't. | 2+ |
| A3→A2-004 | Add a Bug-3 regression to A2-007 ArgoCD drift test: pre-seed a Kyverno mutation that flips a field, assert the diff oracle flags it within one cycle. | regression-extension | Codifies the Kyverno-drift recurrence as a test, not a debug expedition. | 1+ |
| A3→A2-005 | A2-026 (extra-field rejection) should also cover a Composition with a missing `type: Format` on a string transform — the literal PR #61 bug. | regression-extension | Pairs the schema-violation negative with the historical concrete bug. | 2+ |
| A3→A2-006 | Extend A2-046 (spoke teardown) to enumerate by tag `managed-by=k8-platform` against the sandbox account, catching orphans across regions us-east-1 + us-west-2. | regression-extension | Sandbox-kill class; cross-region orphans are uniquely silent. | 3+ |
| A3→A2-007 | Add a soak-test variant of A2-018 that runs across an SA token's 1h TTL boundary specifically (timed for T+59m), asserting refresh path works. | regression-extension | The 1h TTL is the documented IRSA failure-time landmark. | 2+ |
| A3→A2-008 | Pair A2-031 (helm chart version lock) with a contract test that the chart digests in terraform match those resolved at `helm pull` time. | regression-extension | Version pin + digest pin = real reproducibility. | 1+ |
| A3→A2-009 | Extend A2-042 (CloudTrail apply audit oracle) to also assert no out-of-band `RunInstances` events occurred during the apply window — sandbox-cap guard. | regression-extension | Cap exceedance has been the most catastrophic class historically. | 0+ |
| A3→A2-010 | A2-058 (PR #61 `type: Format` regression) could be promoted to a fixture-driven negative suite where every past Composition bug gets its own fixture file. | regression-extension | Bug-class registry as living test corpus, not just doc. | 2+ |
| A3→A2-011 | Extend A2-064 (destroy phase 2 only) to verify phase-1 IRSA roles still match their phase-1 SAs after the destroy, not just helm health. | regression-extension | Cross-phase blast-radius checks; AGENTS.md §5 invariant 1 has IRSA implications. | 2+ |
| A3→A2-012 | Add a regression for the "Apply complete: 0 added silent no-op": run a known-mutating change with `triggers_replace` hash deliberately missing one manifest, assert the apply-and-verify oracle flags it. | regression-extension | Codifies PR #67 root cause as a test. | 0+ |
| A3→A2-013 | Pair A2-019 ArgoCD soak with a Logs Insights oracle that asserts zero `OutOfSync` log lines for any app over the 90-min window. | regression-extension | Belt-and-suspenders for the documented Bug-3 recurrence. | 1+ |
| A3→A2-014 | Extend A2-035 (concurrency + chaos) with a CloudWatch metric oracle for AWS API throttling — assert no `ThrottlingException` surge during the burst. | regression-extension | Sandbox-cap-style invariant on API quota, not just instance count. | 2+ |
| A3→A2-015 | Add a contract test that every ClusterPolicy in `policies/audit/` has a corresponding fixture both for pass and fail to prove enforce-mode upgrade is safe. | regression-extension | Audit-to-enforce upgrade has historically been the highest-risk transition. | 1+ |

### from A4

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

### from A5

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

### from A6

| ID | Idea | Category | Justification | Applies to phase |
|---|---|---|---|---|
| A6→A2-001 | Once A2-001's SDK readback works, retire any chainsaw `assert` block that only checks `.status.conditions[*].Ready` on the XR — the SDK is a stronger oracle. | refactor | Stronger gate replaces weaker one. | 2+ |
| A6→A2-002 | IRSA simulate-principal-policy test (A2-003) supersedes the inline `aws iam get-role-policy` greps in `test_irsa_policy_completeness.sh`. | simplification | API-level oracle replaces text-grep heuristics. | 1+ |
| A6→A2-003 | A2-004 (live AssumeRoleWithWebIdentity) makes every "does this IRSA work" smoke test pod (deployed just to call STS) deletable. | simplification | Test runner does it directly; no test workload needed. | 1+ |
| A6→A2-004 | A2-005 + A2-006 bidirectional IRSA invariants collapse `test_irsa_trust_subject.sh` and `test_irsa_sa_annotation.sh` into one parameterized test. | refactor | One invariant, two directions. | 1+ |
| A6→A2-005 | ArgoCD admin-API drift test (A2-007) retires manual "argocd app diff" runbooks in `ai/runbooks/` (or wherever the historical equivalents live). | simplification | Automated drift > documented drift hunt. | 1+ |
| A6→A2-006 | Full E2E claim->ASM byte-compare (A2-034) makes the layered tests A2-001 + A2-012 + A2-053 partially redundant — once the byte-compare passes, those become smoke-only. | refactor | Single end-to-end oracle subsumes mid-chain probes. | 2+ |
| A6→A2-007 | A2-016 (parallel claim fan-out) lets us delete the now-pointless "test_uid_uniqueness.sh" lint — runtime exercises it for real. | simplification | Runtime test trumps static heuristic. | 2+ |
| A6→A2-008 | A2-022 chaos test on Crossplane pod kill obviates the manual `crossplane-reset-provider.sh` runbook step — automated test proves recovery works. | simplification | Test = living documentation. | 2+ |
| A6→A2-009 | A2-020 (authoritative `dig`) lets us delete every public-resolver `dig @8.8.8.8` invocation lingering in scripts/runbooks. | refactor | One correct DNS oracle. | 1+ |
| A6→A2-010 | A2-046 (post-teardown SDK enumeration) makes manual "did I clean up?" handoff checklist items obsolete. | simplification | Test enforces invariant. | 3+ |
| A6→A2-011 | A2-064 (phase-2-destroy invariant) lets us delete the verbal AGENTS.md §5 invariant 1 reminder — test enforces it. | simplification | Executable invariants > prose invariants. | 2+ |
| A6→A2-012 | A2-031 contract test (chart-version mirror) lets us delete the manual chart-version-bump checklist in PR templates. | simplification | Lint catches drift; checklist becomes redundant. | 1+ |
| A6→A2-013 | A2-019's soak test obviates ad-hoc "is ArgoCD still OK?" status polling in long sessions. | simplification | Soak test result is the answer. | 1+ |
| A6→A2-014 | A2-009's realm-lifecycle test removes the need for the manually-maintained "Keycloak smoke test steps" doc. | simplification | Code replaces prose. | 5+ |
| A6→A2-015 | Combine A2-014 + A2-015 + A2-022 + A2-023 into a single chaos-suite runner; each test currently bootstraps its own kill-and-watch scaffolding. | refactor | Shared scaffolding cuts code by ~60%. | 2+ |

### from PRIMARY

| ID | Idea | Category | Justification | Applies to phase |
|---|---|---|---|---|
| P→A2-001 | A "test pyramid health" report that emits coverage-by-phase × layer (unit/kyverno/integration/chainsaw/e2e) and flags layers that haven't been touched in 30 days. | meta-test | Catches "we stopped writing chainsaw tests halfway through phase 2" before it becomes a habit. | 2+ |
| P→A2-002 | A property-based test harness that generates random valid PlatformSecret claim specs and asserts the round-trip invariant (claim accepted ⇒ ASM secret exists with matching tags). | property-test | Surfaces edge cases (long names, unicode descriptions, weird refresh intervals) that example-based tests miss. | 2+ |
| P→A2-003 | A "bug regression corpus" directory: every retro'd bug gets a one-file reproducer kept forever; CI runs the whole corpus on every PR. | regression-corpus | Turns institutional memory of past bugs into permanent guardrails. | 0+ |
| P→A2-004 | A cross-phase soak test that holds phase-2 claims live for 24 hours and asserts no MR flapping, no IRSA token expiry, no ArgoCD drift events. | soak-test | Catches slow-burn issues (token-lifetime mismatches, refresh-interval bugs) invisible to short tests. | 2+ |
| P→A2-005 | A "tear-down completeness" test that deletes a phase-2 claim and asserts every cloud resource it created is actually gone (ASM secret, IAM bindings, tags). | e2e-test | Defends against "ghost resources" that quietly accumulate cost. | 2+ |
| P→A2-006 | A negative-IRSA test that intentionally swaps the SA name on a deployment and asserts the provider goes Unhealthy within N seconds (regression for PR #66/#68). | irsa-test | Locks the SA-pinning fix permanently. | 1+ |
| P→A2-007 | A "manifest hash drift" test that mutates the body of a manifest controlled by `terraform_data.triggers_replace` without bumping the trigger and asserts the diff is detected (regression for PR #67). | unit-test | Prevents reintroduction of "edited the manifest but apply was a no-op". | 1+ |

