# Cross-review additions from A6

A6's lens: removal & refactor — "this was awkward, now simpler". Every suggestion below is additive (no criticism of source ideas); it identifies cruft each idea lets us retire, collapse, or simplify.

## For A1-debug-tools-max-capability.md

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

## For A2-integration-e2e-tests-max-capability.md

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

## For A3-test-gaps-prior-constraints.md

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

## For A4-debug-tool-gaps-prior-constraints.md

| ID | Idea | Category | Justification | Applies to phase |
|---|---|---|---|---|
| A6→A4-001 | A4-002's generic `kubectl-exec.yml` lets us delete A4-001 (read-cluster), A4-018 (events-since), A4-021 (pod-restart-watch), A4-041 (tail-pod-logs), A4-043 (previous-container-logs), and A4-047 (kubectl-diff) — all are kubectl-verb specializations. | simplification | One generic bridge subsumes six specific ones. | 1+ |
| A6→A4-002 | A4-003's generic `aws-cli.yml` similarly subsumes A4-024 (route53), A4-026 (cognito), A4-027 (ACM), A4-028 (VPC), A4-079 (CloudTrail) and A4-080 (IAM simulator) once read-only allowlist is in place. | simplification | One generic AWS bridge replaces seven specific dumps. | 0+ |
| A6→A4-003 | Now that the sandbox runs kubectl/aws directly, *every* `*.yml` dispatch workflow in A4 (~70 items) becomes a shell script — retire the dispatch-workflow pattern entirely once the new sandbox is the norm. | refactor | Dispatch workflows existed only because of the prior constraint. | 0+ |
| A6→A4-004 | A4-014 (dispatch-then-read-step) + A4-017 (dispatch-and-poll) + A4-091 (watch-tee) collapse into one canonical `gh-run.sh` helper. | refactor | Three helpers, one job. | 0+ |
| A6→A4-005 | A4-009 (workflow-log-fetch) + A4-015 (grep-workflow-log) + A4-050 (gather-bug-evidence) + A4-070 (gh-pr-checks-evidence) form one "GH log toolkit" — ship as one script with subcommands. | refactor | Unified surface. | 0+ |
| A6→A4-006 | A4-038 (wait-for-condition) + A4-039 (wait-for-argocd) + A4-040 (wait-for-claim) collapse into one parameterized waiter mirroring A1-021. | simplification | Same loop, three callers. | 1+ |
| A6→A4-007 | A4-010..A4-013 (four runbooks) merge into one `runbooks/` directory with a shared decision-tree format; A4-059 (decision-tree-runner) then drives all of them. | refactor | Consistent format, single runner. | 0+ |
| A6→A4-008 | A4-005's crossplane-trace, once it exists as a script (per A1-019), retires the dispatch-workflow form of the same idea. | simplification | One implementation. | 2+ |
| A6→A4-009 | A4-067 (auto-updated dispatch-history.md) lets us delete the manual "what did I run this session?" reconstruction in handoff. | simplification | Auto > manual. | 0+ |
| A6→A4-010 | A4-029's quota-preflight + A1-035's local quota-check are duplicates — keep one, drop the other. | refactor | One preflight. | 0+ |
| A6→A4-011 | A4-075 (apply-line-summary) + A4-008 (plan-diff summary) form one "tf-output-summarizer" — collapse. | refactor | Same parser, two outputs. | 0+ |
| A6→A4-012 | A4-051 (workflow-yaml-lint) + A3-014 (workflow YAML safe_load lint) are the same lint — keep one. | simplification | One yaml validator. | 0+ |
| A6→A4-013 | A4-068's IRSA trust-vs-tf diff replaces the entire post-#66 "manually check the role" runbook step. | simplification | Diff is the runbook. | 1+ |
| A6→A4-014 | A4-036 + A4-037 (bundle producer + extractor) lets us delete every ad-hoc "describe everything" workflow scattered across the .github/workflows/ tree. | refactor | One bundle format. | 1+ |
| A6→A4-015 | A4-076 (silent-pass-detector) and A3-004 + A3-005 are the same lint family — merge into one `lint_shell_strictness.sh`. | refactor | Cross-file dedupe. | 0+ |

## For A5-orchestration-post-actions.md

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
