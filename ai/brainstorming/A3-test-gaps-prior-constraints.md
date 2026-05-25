# A3 — Test Gaps Under Prior Constraints

- Agent: A3
- Mandate: Brainstorm unit / Kyverno / integration / chainsaw / e2e tests that we should already have written under the OLD constraints (GH Actions only, no admin AWS, no direct kubectl) but never did — mined from retros + PR history — plus refactor/simplify ideas for tests we have.
- Date: 2026-05-25
- Branch: claude/determined-pasteur-53fAN

| ID | Idea (one sentence) | Category | Justification | Applies to phase |
|---|---|---|---|---|
| A3-001 | Static lint that every `helm_release` in `terraform/management/helm.tf` has a corresponding `irsa.tf` module AND vice versa (bidirectional). | unit-test | Would have caught bug 4 (ExternalDNS helm_release entirely missing) from PR #34 — IRSA module existed but no chart consumed it. | 1+ |
| A3-002 | Helm-render assertion that for any chart with per-component ServiceAccounts (argo-cd, crossplane), the IRSA annotation lives at `<component>.serviceAccount.annotations`, not the top-level. | unit-test | Bug 3 from PR #34 (argocd IRSA on wrong SA) — silent until e2e verify. | 1+ |
| A3-003 | Static lint that every Kyverno ClusterPolicy JMESPath literal between backticks parses as valid JSON. | unit-test | Already exists (`test_kyverno_policy_lint.sh`) — but extend to assert non-empty AND valid type per Kyverno schema for `count(@)`, `length(@)` etc. | 1+ |
| A3-004 | Static lint forbidding `set -uo pipefail` without `-e` in every `tests/**/*.sh` and `scripts/**/*.sh`. | unit-test | Silent-PASS bug from run 26347839740 (PR #59); the existing `test_integration_scripts_strict_mode.sh` only covers `tests/integration/`. | 0+ |
| A3-005 | Static lint forbidding assignment to bash readonly built-ins (`UID`, `EUID`, `BASHPID`, `RANDOM`, `SECONDS`, `LINENO`) across all `*.sh` (not just tests). | unit-test | Bug PR #59 in 11_platform_secret_e2e.sh; lint exists but should scan scripts/ and .github/scripts/. | 0+ |
| A3-006 | Unit test asserting every `argocd/apps/*.yaml` Application has either `syncPolicy.automated` OR a doc-comment opt-out header. | unit-test | Would have caught PR #55 manual-sync regression. | 1+ |
| A3-007 | Unit test asserting every XRD with `served: true` also has `referenceable: true` on the storage version. | unit-test | Bug class registered in TESTING-PLAN.md — partial coverage in `test_platform_secret_xrd.sh`, generalize to all XRDs. | 2+ |
| A3-008 | Helm-render assertion that the rendered argocd-server Ingress has `metadata.name` ending in `-server` (regardless of release name) — selector by label `app.kubernetes.io/component=server`. | refactor-test | Pending follow-up #2 in handoff: existing `test_helm_render.sh` checks broken with chart 6.7.3 release-name change; tolerated via `continue-on-error`. | 1+ |
| A3-009 | Unit test asserting every Composition's `function-patch-and-transform` `type: string` transform has `.string.type: Format` (or other valid subtype). | unit-test | Already exists (`test_composition_string_transform_type.sh`); extend to validate the format string references resolvable patches. | 2+ |
| A3-010 | Unit test asserting every Composition `patch` with `fromFieldPath: metadata.namespace` on a cluster-scoped XR is replaced with `spec.claimRef.namespace`. | unit-test | Bug-class row in TESTING-PLAN.md ("ExternalSecret silently lands in crossplane-system"); partial coverage in `test_platform_secret_composition.sh`, generalize. | 2+ |
| A3-011 | Static lint that every `terraform_data.<x>.triggers_replace` lifecycle hash includes `sha256()` of any inline manifest the resource provisions. | unit-test | Bug PR #67 (`triggers_replace` miss, manifest edit was a no-op). | 1+ |
| A3-012 | Unit test asserting `tests/chainsaw/versions.env` mirrors every Crossplane-related pin in `terraform/management/variables.tf`. | unit-test | Already exists for chart version (`test_chainsaw_kind_config.sh`); extend to provider-family-aws, function-patch-and-transform, kind version. | 2+ |
| A3-013 | Unit test asserting any GitHub Actions workflow that runs `curl ... -o /usr/local/bin/X` is preceded by `sudo` (or uses `$HOME/.local/bin`). | unit-test | Bug PR #51 (chainsaw install missing sudo on ubuntu-24.04). | 0+ |
| A3-014 | YAML-validity lint over every `.github/workflows/*.yml` that parses via `python -c yaml.safe_load` and rejects unindented heredocs inside `run: |` blocks. | unit-test | Bug PR #65 (workflow_dispatch silently absent on malformed YAML). | 0+ |
| A3-015 | Unit test asserting every `.github/workflows/*.yml` job with `workflow_dispatch` declares all `inputs` used in the body via `${{ inputs.X }}`. | unit-test | Multiple workflow_dispatch issues across PRs #57, #58, #60. | 0+ |
| A3-016 | Helm-render lint asserting `server.ingress.hostname` is set when ingress is enabled (singular key for chart 6.7.x). | unit-test | Bug 7 PR #34 (`hosts[0]` vs `hostname`). | 1+ |
| A3-017 | IRSA-policy completeness test extension: assert ExternalDNS policy includes `route53:ListHostedZones` AND `ListHostedZonesByName` AND `ChangeResourceRecordSets`. | iam-policy-completeness-test | Bug 6 PR #34 — runtime AccessDenied loop. | 1+ |
| A3-018 | IRSA trust-policy completeness test: assert every IRSA role's trust `Condition.StringEquals` subject EXACTLY matches the SA name in the consuming helm_release values. | irsa-trust-test | Bug 5 PR #66 (hash-suffixed SA name not pinned). | 1+ |
| A3-019 | Unit test asserting `DeploymentRuntimeConfig.spec.serviceAccountTemplate.metadata.name` is pinned (non-empty) for every Crossplane provider that uses IRSA. | unit-test | Bug 5 PR #66 — direct defending lint. | 2+ |
| A3-020 | Unit test scanning Kyverno ClusterPolicies for missing `spec.admission`, `spec.background`, or `pod-policies.kyverno.io/autogen-controllers` annotation (the drift triad). | unit-test | Already partially in `test_kyverno_policy_lint.sh`; extend to every audit policy. Bug 3 from PR #64. | 1+ |
| A3-021 | Static lint asserting every ArgoCD Application uses a pinned `targetRevision` (commit SHA or tag, not `HEAD` or branch). | unit-test | Already exists (`test_argocd_app_revision_pinned.sh`); extend to forbid `main` as a value. | 1+ |
| A3-022 | Kyverno audit policy: deny ClusterPolicy without explicit `spec.admission` field. | kyverno-policy | Runtime equivalent of A3-020 — catches drift introduced by hand. | 1+ |
| A3-023 | Kyverno audit policy: warn on any Deployment in `crossplane-system` whose `spec.template.spec.serviceAccountName` does NOT match a pinned `upbound-provider-*` allowlist. | kyverno-policy | Bug 5 PR #66 visible at runtime. | 2+ |
| A3-024 | Kyverno audit policy: deny ExternalSecret whose `spec.secretStoreRef.name` is not in the known ClusterSecretStore allowlist. | kyverno-policy | Catches typos that silently fail to fetch secrets. | 2+ |
| A3-025 | Kyverno audit policy: deny Composition with `mode: Resources` (legacy v1 mode) — require Pipeline. | kyverno-policy | PR #51 migrated to Pipeline; prevents regression. | 2+ |
| A3-026 | Kyverno audit policy: deny Crossplane Provider without a referenced DeploymentRuntimeConfig. | kyverno-policy | Defends the IRSA-binding contract at runtime. | 2+ |
| A3-027 | Kyverno audit policy: warn on ArgoCD Application with `syncPolicy.automated.selfHeal: false`. | kyverno-policy | Drift surface; PR #54/#55 introduced manual-sync apps that need explicit opt-out documentation. | 1+ |
| A3-028 | Kyverno audit policy: deny any Secret in any namespace whose `data` size > 4KB without `eso.io/managed: true` annotation. | kyverno-policy | Detects hand-applied secrets that bypass ESO. | 1+ |
| A3-029 | Integration test that dispatches `phase-2-diagnose.yml` and asserts every expected dump section is present (XR yaml, MR yamls, events, controller logs). | integration-test | PR #60 has no regression test — could silently lose a section. | 2+ |
| A3-030 | Integration test that applies a PlatformSecret claim with `spec.foo: bar` (unknown field) and asserts the apply is REJECTED by strict-schema. | integration-test | Pending follow-up #6 in handoff (strict-schema rejection scenario). | 2+ |
| A3-031 | Integration test that creates two PlatformSecret claims in different namespaces with the SAME name and asserts no ASM key collision. | integration-test | UID-shadowing bug PR #59 root cause (ASM key was `k8-platform/1001` for every claim); the runtime defense. | 2+ |
| A3-032 | Integration test that performs a Composition edit via git → ArgoCD sync → assert the XR sees the new Composition revision within 3 min. | integration-test | PR #67/#68 cluster-state-divergence bug class ("apply succeeded ≠ change reached cluster"). | 2+ |
| A3-033 | Integration test that mutates a Kyverno ClusterPolicy field on the cluster directly and asserts ArgoCD reports OutOfSync within 3 min. | integration-test | Bug 3 PR #64 — Kyverno drift detection requires this test. | 1+ |
| A3-034 | Chainsaw scenario: apply PlatformSecret claim, edit `spec.refreshInterval` via patch, assert new value propagates to ExternalSecret. | chainsaw | Composition patch-back not covered by existing 00/01/02 scenarios. | 2+ |
| A3-035 | Chainsaw scenario: delete the Composition while a claim exists, assert XR transitions to `Synced=False` with informative message. | chainsaw | Failure-mode coverage; today undefined. | 2+ |
| A3-036 | Chainsaw scenario: apply a malformed claim (missing required field) and assert the API server rejects with the OpenAPI message, not a generic 500. | chainsaw | XRD schema strictness defense. | 2+ |
| A3-037 | Chainsaw scenario: simulate provider package install failure (404 image) and assert the Composition reports `pkg.crossplane.io/healthy=False` within 60s. | chainsaw | Bug class: silent provider non-install in PR #51. | 2+ |
| A3-038 | Chainsaw scenario for PlatformCluster: apply claim, assert XR's `resourceRefs` lists all 8 expected MRs (2 IAM roles, 4 attachments, EKS, NodeGroup). | chainsaw | XRD/Composition shape regression defense for phase 2b. | 2+ |
| A3-039 | Unit test asserting every `clusters/<cluster>/*.yaml` ArgoCD app references an existing `crossplane/claims/` file. | unit-test | Phase-3 scaffolding (PR #55) introduced this pattern with no lint. | 3+ |
| A3-040 | Unit test asserting `.github/scripts/post-comment.py` `OUTCOMES` and `STEP_LABELS` keys are equal sets. | unit-test | Already exists (`test_post_comment.sh`); add scenarios for every `phase` value. | 0+ |
| A3-041 | Unit test asserting every shell script under `scripts/` and `tests/` runs `shellcheck` clean (or has documented SC#### exclusions). | unit-test | Latent `$SELECTOR` typo PR #46 — shellcheck would catch it. | 0+ |
| A3-042 | Refactor: replace per-test `wait_for` bash loops in `tests/integration/*.sh` with a single library helper that exits non-zero AND prints last-seen state. | refactor-test | Silent-PASS bug PR #59 — strict-mode + canonical helper would remove the bug class. | 1+ |
| A3-043 | Simplify: collapse `tests/unit/test_platform_secret_xrd.sh` and `test_platform_cluster_xrd.sh` into a single parameterized XRD lint runner. | simplify-test | Duplication grows linearly per XRD; one lint per invariant scales. | 2+ |
| A3-044 | Simplify: replace bespoke yq selectors in `test_helm_render.sh` with a fixture-driven loop reading expected resource shapes from `tests/unit/fixtures/helm/*.yaml`. | refactor-test | Pending follow-up #2 — chart-version selector brittleness. | 1+ |
| A3-045 | Helm-render test asserting the ingress class on every chart-rendered Ingress matches `nginx` (not `alb`, not empty). | helm-render-test | Pre-existing `02-ingress-must-have-class.yaml` is runtime-only; authoring-time would be faster. | 1+ |
| A3-046 | Unit test asserting every `policies/audit/*.yaml` policy has `validationFailureAction: Audit` (never Enforce by accident). | unit-test | Drift-prevention — Enforce on a buggy policy bricks apply. | 1+ |
| A3-047 | Unit test asserting every Crossplane Composition `function` reference uses a pinned version (no `latest`, no missing tag). | unit-test | Composition v2 pipeline migration PR #51 — function pinning matters for behavior reproducibility. | 2+ |
| A3-048 | Unit test asserting `terraform/management/variables.tf` chart-version defaults match versions referenced in `argocd/apps/*.yaml` Helm-chart Applications. | unit-test | Cross-source-of-truth drift — caught zero times today. | 1+ |
| A3-049 | Unit test asserting every `.github/workflows/*.yml` that does an AWS API call has `permissions: id-token: write` (OIDC) or documents long-lived creds. | unit-test | Slightly out-of-period for current creds model but defends future migration. | 0+ |
| A3-050 | Unit test asserting `terraform/management/eks.tf` enables all 5 control-plane log types (api, audit, authenticator, controllerManager, scheduler). | unit-test | Operational visibility — IRSA/RBAC bugs cannot be retro-debugged without audit/authenticator logs. | 1+ |
| A3-051 | Unit test asserting every IRSA role has a non-empty `inline_policy` or `managed_policy_arns` (catches half-finished modules). | iam-policy-completeness-test | Bug class: a role exists but has no permissions — produces silent AccessDenied. | 1+ |
| A3-052 | Unit test asserting every Crossplane ProviderConfig referenced by a Composition resource exists in `crossplane/providers/`. | unit-test | Composition with `providerConfigRef: nope` is a silent runtime failure. | 2+ |
| A3-053 | Helm-render assertion that the rendered Crossplane chart includes a DeploymentRuntimeConfig matching the IRSA SA name expected by `irsa.tf`. | helm-render-test | Authoring-time defense for the bug 5 / PR #66 chain. | 1+ |
| A3-054 | Unit test asserting every Composition `patch` with `type: ToCompositeFieldPath` has a matching `FromCompositeFieldPath` in the inverse direction (catches stale patches). | unit-test | Composition rot — patches that only flow one way silently drop status. | 2+ |
| A3-055 | Integration test that applies a Composition revision bump and asserts the existing XR reconciles the change within 3 min (vs being orphaned at old revision). | integration-test | Composition versioning semantics — currently undefined behavior. | 2+ |
| A3-056 | Chainsaw scenario asserting that a deleted XRD properly cleans up all composed MRs (no orphans). | chainsaw | Lifecycle invariant for phase-2 teardown — PR #58. | 2+ |
| A3-057 | Unit test asserting `scripts/diag-component.sh` handles every component name listed in its own usage string (parity check). | unit-test | Latent `$SELECTOR` typo PR #46 — parity test catches per-component breakage. | 0+ |
| A3-058 | Unit test asserting every Kyverno ClusterPolicy uses `apiVersion: kyverno.io/v1` consistently (no v1beta1 drift). | unit-test | API drift detection; cheap. | 1+ |
| A3-059 | Refactor: replace `tests/integration/run.sh`'s sequential test runner with `set -e` orchestration that aborts on first failure, then dumps state. | refactor-test | Silent-PASS PR #59 — runner-level defense. | 1+ |
| A3-060 | Unit test asserting every `terraform_data` resource with `provisioner local-exec` includes `command` body content sha256 in `triggers_replace`. | unit-test | Direct generalization of bug PR #67. | 1+ |
| A3-061 | Chainsaw scenario asserting Composition pipeline step ordering produces deterministic XR resourceRefs (no flaky test). | chainsaw | Bug PR #53 (non-deterministic XRD condition order). | 2+ |
| A3-062 | Unit test asserting every chainsaw `script:` block uses POSIX-only constructs (no `[[`, no arrays, no `set -o pipefail`). | unit-test | Bug PR #53 (`pipefail` on dash). | 2+ |
| A3-063 | Helm-render test that argocd-server Service is of type ClusterIP (NLB termination is at ingress only). | helm-render-test | Sneaky regression class — chart upgrade could flip default. | 1+ |
| A3-064 | Unit test asserting every Composition that references AWS resources sets `spec.providerConfigRef.name` to a value in the known allowlist (`default`, `irsa-default`). | unit-test | Catches typos pre-apply. | 2+ |
| A3-065 | Integration test that probes ArgoCD `application.argoproj.io/bootstrap` is `Synced/Healthy` AND its self-exclusion ignoreDifferences is preserved. | integration-test | App-of-apps PR #43 has no live-cluster test. | 2+ |

## Cross-review additions

Additive, collaborative extensions from every other agent and the primary orchestrator. No criticism — only amplifications, related ideas, pairings, and meta-observations.

### from A1

| ID | Idea | Category | Justification | Applies to phase |
|---|---|---|---|---|
| A1→A3-001 | Extend A3-050 (control-plane log types) with a unit test that every enabled log type has a matching CloudWatch Logs Insights saved-query in the repo. | observability-pair | Enabled logs nobody queries are just storage cost. | 1+ |
| A1→A3-002 | Add a lint that every Kyverno policy in `policies/audit/` has a corresponding CloudWatch metric filter on PolicyReport events so violations are graphable. | observability-test | Audit-mode invisible without surfaced metrics. | 1+ |
| A1→A3-003 | Pair A3-017 (ExternalDNS IAM completeness) with a lint that every IRSA inline policy's actions are also enumerated in a matching `iam-actions-required.yaml` doc — drift-proof permission spec. | iam-policy-completeness-extension | Source-of-truth split prevents silent policy widening. | 1+ |
| A1→A3-004 | Extend A3-029 (diagnose dump regression test) by asserting each dump section's byte size is within ±50% of a recorded baseline — empty dumps become loud. | observability-test | Silent regressions where a section becomes empty are common. | 2+ |
| A1→A3-005 | Add a unit test that every CloudWatch alarm in terraform has an `alarm_actions` (SNS topic) and at least one subscriber — defends against silent alarms. | observability-test | Alarms without actions are a known anti-pattern. | 1+ |
| A1→A3-006 | Pair A3-033 (Kyverno drift detection integration test) with a unit-level lint that every Kyverno mutate-rule has `mutateExistingOnPolicyUpdate: false` unless explicitly opted in. | unit-test | Defends Bug 3 at authoring time, not just runtime. | 1+ |
| A1→A3-007 | Extend A3-041 (shellcheck across scripts) to also run `shfmt -d` so formatting drift is a separate, fast signal from semantic issues. | refactor-test | Makes shellcheck output less noisy. | 0+ |
| A1→A3-008 | Add a unit test asserting every Terraform `aws_cloudwatch_log_group` has `retention_in_days` set explicitly (no infinite retention by accident — sandbox quota matters). | unit-test | Storage creep can hit sandbox cost limits. | 0+ |
| A1→A3-009 | Pair A3-046 (audit-only Kyverno lint) with a unit test that every `policies/enforce/` policy has a corresponding audit-mode predecessor in git history (proven via shadow run). | unit-test | Codifies the safe enforce-mode promotion path. | 1+ |
| A1→A3-010 | Extend A3-058 (Kyverno apiVersion lint) to also assert `failurePolicy: Fail` is intentional and reviewed (annotation required), defending against accidental fail-open. | unit-test | Fail-open Kyverno bricks half a policy with no signal. | 1+ |
| A1→A3-011 | Add a static lint that every Crossplane Composition references at least one observability annotation (`platform.io/owner`, `platform.io/runbook-url`) so XR debugging has a starting point. | unit-test | Orphan XRs with no owner take forever to triage. | 2+ |
| A1→A3-012 | Pair A3-031 (UID-shadowing integration test) with a lint that every ASM-writing Composition's external-name template includes `${xr.metadata.uid}` (or equivalent) — bug 5 at authoring time. | unit-test | Defends UID-collision at PR time. | 2+ |
| A1→A3-013 | Add a contract test that every IRSA role has an `aws_iam_role.tags.purpose` tag that matches the SA name — observability tag invariant. | iam-policy-completeness-test | Untaggged roles are unsearchable in CloudTrail. | 1+ |
| A1→A3-014 | Extend A3-065 (bootstrap App integration test) with a CloudTrail event assertion that ArgoCD's IRSA role's last AssumeRoleWithWebIdentity is < 10 min old. | integration-test-extension | Detects bootstrap-up-but-token-stale. | 2+ |
| A1→A3-015 | Add a unit test asserting every `tests/integration/*.sh` includes a `trap '<state-dump-fn>' EXIT` so failures auto-attach evidence (codifies Silent-PASS PR #59 lesson positively). | unit-test | Universal evidence-on-exit is the cheapest reliability win. | 1+ |

### from A2

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

### from A4

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

### from A5

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

### from A6

| ID | Idea | Category | Justification | Applies to phase |
|---|---|---|---|---|
| A6→A3-001 | A3-043 (XRD lint consolidation) is the right model — extend it: every per-claim-kind test in `tests/unit/test_platform_*.sh` should become a single fixture-driven runner. | refactor | Eliminates linear-growth duplication. | 2+ |
| A6→A3-002 | A3-042's library helper for `wait_for` lets us delete every per-test bash retry loop AND simplify A1-021's wait-for-claim — both can call the same lib. | simplification | One wait lib, used by helpers + tests. | 1+ |
| A6→A3-003 | A3-005 (forbid assignments to bash readonly built-ins) plus A3-004 (strict-mode lint) belong in one `lint_shell_strictness.sh` — collapse them. | refactor | One lint, two rules. | 0+ |
| A6→A3-004 | A3-022 (Kyverno policy enforcing A3-020) makes A3-020 the authoritative source; the static lint can then be retired. | simplification | Runtime gate is stronger than static. | 1+ |
| A6→A3-005 | A3-039 (cluster-app references claim file) combined with A3-052 (providerConfigRef exists) becomes a single "reference-integrity" linter across all YAML. | refactor | Pattern is "ref → must exist"; one tool. | 2+ |
| A6→A3-006 | A3-011 + A3-060 are the same lint (manifest sha256 in triggers_replace); merge them. | simplification | Two rows, one tool. | 1+ |
| A6→A3-007 | A3-029's diagnose-section-presence test, once it lands, lets us retire the manual review step "did the diagnose dump include X?" in PR templates. | simplification | Test catches it; humans don't have to. | 2+ |
| A6→A3-008 | A3-018 (IRSA trust subject pinned to SA name) and A3-019 (DeploymentRuntimeConfig SA pinned) collapse into one "IRSA binding integrity" suite covering the whole PR #66/#68 bug chain. | refactor | One test asserts the chain end-to-end. | 1+ |
| A6→A3-009 | A3-014 + A3-015 + A3-049 are all "workflow YAML correctness" linters; ship them as one actionlint config plus one custom rule pack. | refactor | One toolchain not three. | 0+ |
| A6→A3-010 | A3-058 (apiVersion drift) is one instance of a wider class — generalize to "every YAML manifest in repo uses the apiVersion currently served by the registered CRD". | refactor | One generalized lint kills a family of drift bugs. | 1+ |
| A6→A3-011 | A3-059's `set -e` orchestration in run.sh lets us delete the per-test "did the previous test pass?" guard code. | simplification | Runner enforces; tests stay focused. | 1+ |
| A6→A3-012 | A3-021 + A3-052 + A3-064 are "every X must point at known Y in allowlist Z" lints — generalize as a single declarative ref-integrity tool driven by a YAML config. | refactor | One tool replaces N hardcoded lints. | 1+ |
| A6→A3-013 | Once A3-033 (Kyverno drift detection runtime test) is live, the related static lint A3-020 can be downgraded to a fast smoke check or removed. | simplification | Runtime > static for drift. | 1+ |

### from PRIMARY

| ID | Idea | Category | Justification | Applies to phase |
|---|---|---|---|---|
| P→A3-001 | A unit test that lints every shell script in the repo for `set -euo pipefail` + no readonly built-in assignment (`UID=`, `PWD=`, etc.) — the silent-PASS class. | unit-test | Catches the bug class behind PRs #46, #59 once and forever. | 0+ |
| P→A3-002 | A test that greps every workflow YAML for `continue-on-error: true` and requires a justification comment on the same line, or fails. | unit-test | Prevents "passed because the step was allowed to fail" — a recurring evidence-trust bug. | 0+ |
| P→A3-003 | A `tests/unit/test_no_account_id_hardcoded.sh` that fails on any 12-digit AWS account ID in `ai/`, `terraform/`, `crossplane/`, `argocd/`, `scripts/` (per AGENTS.md §8.1). | unit-test | Makes the §8.1 rule enforceable rather than aspirational. | 0+ |
| P→A3-004 | A Kyverno audit policy asserting every ServiceAccount referenced by an IRSA role's trust policy actually exists in the cluster (cross-resource consistency). | kyverno-policy | Catches the SA-name-drift class at runtime, not just apply-time. | 1+ |
| P→A3-005 | A chainsaw scenario per XRD that boots a kind cluster with crossplane + a mocked AWS provider and exercises the composition; runs in <2 min on every PR. | chainsaw | Provides "did the composition actually render?" coverage without touching real AWS. | 2+ |

