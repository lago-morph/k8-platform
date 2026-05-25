# Cross-review additions from A2

Author: A2 (max-capability integration & e2e tests perspective)
Date: 2026-05-25
Mode: additive-only — extensions, test-oracle promotions, smoke-test hardening, and new scenario sparks. No criticism.

## For A1-debug-tools-max-capability.md

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

## For A3-test-gaps-prior-constraints.md

| ID | Idea | Category | Justification | Applies to phase |
|---|---|---|---|---|
| A2→A3-001 | Promote the helm-render IRSA-annotation lint (A3-002) into a live e2e probe that, post-apply, kubectl-reads the SA and asserts the annotation matches. | extension | Static + runtime double-cover catches drift between helm values and rendered cluster state. | 1+ |
| A2→A3-002 | Extend A3-007 (XRD `served`/`referenceable`) with an e2e test that creates a claim against every XRD and asserts the API server actually returns the storage version. | extension | Marker-bit lint plus live verification. | 2+ |
| A2→A3-003 | Couple A3-017 (ExternalDNS IAM policy completeness) with a live test that performs each listed Route53 API call from inside an ExternalDNS pod via `kubectl exec`. | extension | Static policy presence + real API call = real coverage. | 1+ |
| A2→A3-004 | Add a soak-companion to A3-031 (UID-shadow collision) that runs the cross-namespace create loop for 30 min to catch slow-collision modes. | new-scenario | Sustained pressure surfaces collision bugs the single-shot misses. | 2+ |
| A2→A3-005 | Extend A3-032 (Composition edit → ArgoCD sync) with an SDK readback that asserts the new field actually changed the underlying ASM tag/value. | extension | "Synced" is necessary not sufficient; SDK truth closes the gap. | 2+ |
| A2→A3-006 | Pair A3-033 (Kyverno drift detection) with an automated revert step and assert ArgoCD self-heal restores within deadline. | extension | One test exercises both detection and recovery. | 1+ |
| A2→A3-007 | Add an e2e companion to A3-037 (provider package install failure) that confirms a subsequent push of a fixed image recovers within 5 min. | new-scenario | Failure detection + recovery in one scenario. | 2+ |
| A2→A3-008 | Extend A3-038 (PlatformCluster resourceRefs shape) with `aws eks describe-cluster` + `aws iam get-role` assertions per MR. | extension | Cloud-truth oracle for the composite. | 2+ |
| A2→A3-009 | Promote A3-042 (canonical `wait_for` library) and reuse it from every A2 concurrency/soak test (A2-016/017/018/050). | extension | One wait primitive across unit, integration, and e2e layers. | 1+ |
| A2→A3-010 | Add a metamorphic test variant of A3-055 (Composition revision bump) that fires the bump under concurrent claim creation to exercise the race. | new-scenario | Concurrency lens on the revision-handoff bug class. | 2+ |
| A2→A3-011 | Pair A3-056 (XRD teardown orphan cleanup) with an SDK enumeration step asserting no orphan AWS objects remain (per A2-046). | extension | Composes A3 + A2 into a definitive teardown oracle. | 2+ |
| A2→A3-012 | Add a chainsaw companion to A3-019 (DeploymentRuntimeConfig pinned name) that asserts the live Crossplane Deployment uses the pinned SA after a forced rollout. | extension | Runtime witness to the static lint. | 2+ |
| A2→A3-013 | Promote A3-051 (IRSA role policy non-empty) into an `aws iam simulate-principal-policy` smoke test (per A2-003) that runs in CI. | extension | "Non-empty" is necessary but not sufficient; simulator gives semantic correctness. | 1+ |
| A2→A3-014 | Add a soak test on top of A3-027 (selfHeal: false warn) that intentionally mutates the resource over 1h to confirm drift remains visible. | new-scenario | Sustained drift exercises alarm fatigue and dashboard surfacing. | 1+ |

## For A4-debug-tool-gaps-prior-constraints.md

| ID | Idea | Category | Justification | Applies to phase |
|---|---|---|---|---|
| A2→A4-001 | Re-implement A4-001 (`read-cluster.yml`) as a local-shell `read-cluster` script that A2 e2e tests use as the canonical "read live resource" primitive. | test-oracle-promotion | One read path, used both interactively and in tests. | 1+ |
| A2→A4-002 | Promote A4-005 (`crossplane-trace`) to a chainsaw `error:` hook so every failed scenario emits the full claim→XR→MR trace. | test-oracle-promotion | Failure post-mortem is structured. | 2+ |
| A2→A4-003 | Adopt A4-006 (`irsa-check`) as the precondition for every A2 IRSA test (A2-003..A2-006) — refuse to run if check fails. | test-oracle-promotion | Tests fail loudly at preflight instead of producing confusing errors mid-run. | 1+ |
| A2→A4-004 | Use A4-019 (provider-health) as the gating oracle for A2-022 chaos test recovery assertions. | test-oracle-promotion | Reuses one source of truth for "Crossplane is healthy". | 2+ |
| A2→A4-005 | Add a smoke test on top of A4-022 (kyverno-explain) that feeds a known-violating manifest through and asserts the explainer reports the expected failing rule. | smoke-test | Validates the explainer itself. | 1+ |
| A2→A4-006 | Pair A4-024 (route53 snapshot) with A2-020 (ExternalDNS round-trip) to assert the new record appears in the next snapshot diff. | extension | Snapshot tool gains a regression harness. | 1+ |
| A2→A4-007 | Promote A4-025 (NLB target health walker) to the oracle for A2-024 ingress chaos test. | test-oracle-promotion | One walker, two consumers. | 1+ |
| A2→A4-008 | Add an e2e test that A4-032 (composition-render) and the live Composition apply produce byte-identical rendered MRs. | new-scenario | Catches render-vs-apply skew (a known v2 footgun). | 2+ |
| A2→A4-009 | Use A4-035 (eso-trace) as the failure-mode oracle for A2-053 (ASM rotation propagation). | test-oracle-promotion | Six-failure-mode walker collapses into a one-call assertion. | 2+ |
| A2→A4-010 | Pair A4-038 (wait-for-condition) with A1-021 helper to standardize the wait primitive across all A2 soak tests. | extension | Eliminates per-test wait drift. | 1+ |
| A2→A4-011 | Build a regression suite on A4-053 (crossplane-version-skew) that runs nightly and pages on any unexpected drift between core/providers/functions. | smoke-test | Version-skew bugs are silent until they bite; nightly catches them early. | 2+ |
| A2→A4-012 | Extend A4-061 (which-secret-is-stale) into an SLO alarm: any ExternalSecret > 2x refreshInterval since last sync fires a synthetic CW metric. | extension | Stale secrets become observable. | 1+ |
| A2→A4-013 | Use A4-064 (SA IRSA annotation audit) as the live-cluster half of A2-005/A2-006 invariants. | test-oracle-promotion | Bidirectional invariant gets one tool. | 1+ |
| A2→A4-014 | Pair A4-068 (IRSA trust vs TF diff) with A2-003 simulate-principal-policy to catch both subject and permission drift in one run. | extension | Trust + permission coverage in one gate. | 1+ |
| A2→A4-015 | Promote A4-080 (IAM policy simulator) to a contract test that runs for every IRSA role on every PR. | test-oracle-promotion | Pre-flight semantic check instead of mid-deploy AccessDenied. | 1+ |
| A2→A4-016 | Add a chainsaw scenario built on A4-087 (pod projected-token decode) to assert every platform SA's projected token carries the expected `aud` claim. | new-scenario | Tokens silently misconfigured at the pod side is invisible without this. | 1+ |
| A2→A4-017 | Use A4-100 (golden-snapshot diff) as the e2e regression oracle after every A2 chaos test — assert post-recovery state matches the golden. | test-oracle-promotion | Recovery is defined as "return to golden", not just "Ready=True". | 1+ |

## For A5-orchestration-post-actions.md

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

## For A6-removal-refactor.md

| ID | Idea | Category | Justification | Applies to phase |
|---|---|---|---|---|
| A2→A6-001 | Before removing `phase-2-diagnose.yml` (A6-007), port its known-good dump shape into an A2 chainsaw `error:` block so failure post-mortems retain the same level of detail. | preserve-via-test | Don't lose the artifact, just relocate it. | 2+ |
| A2→A6-002 | Before deleting `chainsaw-verify.yml` (A6-008), add an e2e smoke test that asserts every push triggers chainsaw exactly once. | preserve-via-test | Replace SHA-handshake guard with positive coverage. | 2+ |
| A2→A6-003 | When inlining `integration-tests.yml` (A6-010) into `scripts/run-integration.sh`, add a unit test that the script exits non-zero on the silent-PASS class (replicates PR #59 fixture). | preserve-via-test | Don't lose the silent-PASS defense. | 2+ |
| A2→A6-004 | Add an A2 e2e regression after removing `post-comment.py` (A6-014) that the in-PR-body apply summary actually appears on every plan/apply. | preserve-via-test | New reporting path needs its own test. | 0+ |
| A2→A6-005 | Before deleting `test_helm_render.sh` toleration (A6-025), promote its assertions into the A2 helm-render contract suite (paired with A3-008/A3-053). | preserve-via-test | Don't lose the lint, fix it. | 0+ |
| A2→A6-006 | When collapsing chainsaw concurrency (A6-026/A6-027), add an A2 smoke test that two simultaneous local chainsaw runs DO collide (proves we know what we gave up). | meta-test | Document the assumption with a test. | 2+ |
| A2→A6-007 | After A6-038/A6-039 removal (Crossplane v2.0.1 workarounds), add an A2 chaos test specifically targeting the failure modes those workarounds defended against to confirm v2.2 truly handles them. | preserve-via-test | Workaround removal needs a regression net. | 1+ |
| A2→A6-008 | When inlining `compute-gates.sh` (A6-016), add a unit test that the new entry script implements the same gate-skip semantics for already-applied phases. | preserve-via-test | Behavior parity is the contract. | 0+ |
| A2→A6-009 | Pair A6-043 (cheatsheet replacing diagnose dump) with an A2 e2e test that exercises every cheatsheet snippet and asserts they still produce useful output. | preserve-via-test | Cheatsheets rot; tests don't. | 2+ |
| A2→A6-010 | Add an A2 contract test that, after A6-021 (drop zone auto-discovery), confirms `TF_VAR_*` populated from session env matches `aws route53 list-hosted-zones`. | preserve-via-test | Session-env path needs its own consistency check. | 0+ |
| A2→A6-011 | Before A6-046 (delete chainsaw kind-config lint), add an A2 smoke test that a broken kind-config produces a clear chainsaw error within 30s of `make chainsaw`. | preserve-via-test | Replace static lint with live early-fail. | 2+ |
| A2→A6-012 | Pair A6-018 (collapse terraform-test matrix) with an A2 e2e that asserts the new entry script supports each phase×action the old matrix did. | preserve-via-test | Behavior parity test for the migration. | 0+ |
| A2→A6-013 | After A6-023 (delete unit-tests.yml), add a pre-push git hook covered by a smoke test that confirms hook actually blocks a known-failing fixture. | preserve-via-test | New guardrail surface needs proof. | 0+ |
| A2→A6-014 | Pair A6-029 (inline aws-creds-check) with an A2 precondition assert at the top of every e2e suite that STS identity matches expected account. | preserve-via-test | Move check from script to test framework. | 0+ |
| A2→A6-015 | Before A6-001/A6-002/A6-003 (delete ext-github + bridge + spec), add an A2 smoke that direct `gh` CLI calls succeed from the sandbox (proves the bridge is truly obsolete). | preserve-via-test | One-time test confirms the migration premise. | 0+ |
