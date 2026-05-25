# A6 — Removal & Refactor brainstorm

- Agent: A6
- Mandate: Brainstorm things to remove, refactor, or simplify now that the sandbox has direct AWS + kubectl + egress and the old GitHub-Actions-only execution substrate is no longer the only path.
- Date: 2026-05-25
- Branch: claude/determined-pasteur-53fAN

| ID | Idea (one sentence) | Category | Justification | Applies to phase |
|---|---|---|---|---|
| A6-001 | Delete `.claude/skills/ext-github/` entirely. | deprecate-skill | jentic-bridged Actions API access only existed because direct egress to api.github.com was blocked; sandbox now has `gh` and unrestricted egress. | 0+ |
| A6-002 | Delete `.claude/skills/external-api-bridge/` meta-skill and its `reference/procedure.md`. | deprecate-skill | The meta-skill exists only to author `ext-*` jentic bridges, which are obsolete once egress is open. | 0+ |
| A6-003 | Delete `ai/specs/ext-github-design.md` (and the `ai/specs/` dir if it ends up empty). | removal | Design spec for the now-obsolete jentic bridge — single-purpose, no longer drives any live code. | 0+ |
| A6-004 | Remove the "Capability profile" section from `.claude/skills/terraform-ci-watch/SKILL.md` and collapse to a single `gh`-only path. | simplify | Three-profile (`gh` / `github-mcp` / `ext-github`) branching existed only to handle sandboxes without `gh`; current sandbox always has it. | 0+ |
| A6-005 | Delete `.claude/skills/terraform-ci-watch/reference/capabilities.md`. | removal | Per-profile dispatch table is dead with single-profile collapse. | 0+ |
| A6-006 | Simplify `.claude/skills/terraform-ci-watch/reference/log-fetching.md` to assume `gh run view --log`. | simplify | Most of the file describes jentic single-run-GET catalog gaps and partial-MCP fallback — gone with the bridge. | 0+ |
| A6-007 | Delete `.github/workflows/phase-2-diagnose.yml`. | deprecate-workflow | Whole workflow was a dispatch-only state dumper because the agent could not reach `kubectl`; agent now runs the same kubectl commands directly in 2 seconds instead of dispatching+waiting 3 minutes. | 2+ |
| A6-008 | Delete `.github/workflows/chainsaw-verify.yml`. | deprecate-workflow | Existed only as the "look-aside SHA verifier" half of a dispatch-then-prove-it-ran-green dance the agent had to do because it couldn't actually run chainsaw locally; with direct sandbox compute the agent can run the harness itself. | 2+ |
| A6-009 | Collapse the chainsaw `commit_sha` input + verifier handshake in `.github/workflows/chainsaw.yml` to a plain `push`-triggered run. | simplify | The "agent dispatches against a SHA, then a separate workflow looks it up" pattern is GH-Actions-only indirection; with sandbox compute it's just `bash tests/chainsaw/run.sh`. | 2+ |
| A6-010 | Inline `.github/workflows/integration-tests.yml` into a `scripts/run-integration.sh` wrapper. | inline | The workflow is essentially `aws eks update-kubeconfig && tests/integration/run.sh`; agent can run that directly with current sandbox capabilities. | 2+ |
| A6-011 | Remove the `test_filter` workflow input plumbing on `integration-tests.yml`. | simplify | Input existed because the only way to scope was via dispatch; locally `tests/integration/run.sh 11_*` does the same thing. | 2+ |
| A6-012 | Delete `ai/PHASE-2-LIFECYCLE-PLAN.md` after folding its bash blocks into a small `scripts/phase-2-lifecycle.sh`. | consolidate-script | Doc explicitly says it carries the verbatim contents of removed workflow `mode=` steps as a runbook — better as a script the agent invokes. | 2+ |
| A6-013 | Drop `RUNNER_TEMP`, `GITHUB_REPOSITORY`, `GITHUB_SHA`, `GITHUB_REF_NAME` plumbing from `.github/scripts/post-comment.py` once it no longer needs to run inside Actions. | refactor | The PR-summary comment is best produced locally via `gh pr comment` now that the agent runs terraform itself. | 0+ |
| A6-014 | Delete `.github/scripts/post-comment.py` outright. | removal | Once `terraform apply` runs in-sandbox, the agent reports plan/apply diffs in the PR body directly instead of via auto-comment. | 0+ |
| A6-015 | Delete `tests/unit/test_post_comment.sh`. | removal | Unit test only exists to defend the auto-comment script that goes away. | 0+ |
| A6-016 | Inline `.github/scripts/compute-gates.sh` into a tiny terraform `Makefile` or shell helper. | inline | Gate booleans (`base_init`, `base_apply`, ...) are entirely a workflow-step-mux artifact; in-sandbox you just call `terraform init/plan/apply` directly. | 0+ |
| A6-017 | Delete `tests/unit/test_compute_gates.sh`. | removal | Defends `compute-gates.sh`, which goes away with the workflow gate fan-out. | 0+ |
| A6-018 | Collapse `terraform-test.yml`'s 11-step `phase`×`action` matrix into a thin "run `scripts/terraform.sh <phase> <action>`" workflow. | refactor | The huge step-conditional matrix exists to mux gates inside Actions; with direct exec, all that lives in one bash function. | 0+ |
| A6-019 | Remove `terraform-test.yml`'s Bootstrap state-backend step. | refactor | Bucket+DynamoDB create can be a one-shot `scripts/bootstrap-tf-state.sh` the agent runs once per fresh account, not a per-run idempotency dance. | 0+ |
| A6-020 | Remove `terraform-test.yml`'s "Generate Cognito test credentials" step. | refactor | A per-CI-run secret generation block exists because secrets couldn't be set by the agent; sandbox can write `terraform.tfvars` directly with a one-time generated value. | 0+ |
| A6-021 | Drop the Route53 zone auto-discovery step from `terraform-test.yml`. | simplify | The zone is in `aws route53 list-hosted-zones`; agent reads it once per session and exports `TF_VAR_*` — no need for the workflow to redo it on every dispatch. | 0+ |
| A6-022 | Remove the `terraform-validate.yml` workflow and run `terraform fmt -check && terraform validate` as a pre-commit hook. | deprecate-workflow | The push-only validate workflow exists because the agent had no local terraform; sandbox has it. | 0+ |
| A6-023 | Remove the `unit-tests.yml` workflow once the agent runs `tests/unit/run.sh` locally before push. | deprecate-workflow | Per-push CI for unit tests was a guardrail for an agent that couldn't run bash unit tests locally — no longer true. | 0+ |
| A6-024 | Collapse `tests/unit/run.sh` into a single `bats`-style runner instead of the per-test fan-out the unit-tests workflow currently mirrors. | simplify | Per-test workflow steps existed to surface failures in the GH UI; locally one runner with grep'able output is fine. | 0+ |
| A6-025 | Remove the `continue-on-error: true` toleration on `test_helm_render.sh` in `unit-tests.yml` and just fix or delete the test. | refactor | The toleration only exists because no one could iterate without dispatching CI — sandbox now has `helm`. | 0+ |
| A6-026 | Remove the `concurrency:` block from `chainsaw.yml`. | simplify | Concurrency-protect-the-shared-account collision only matters when many CI dispatches race; one-agent-in-one-sandbox just serializes. | 2+ |
| A6-027 | Remove the `CHAINSAW_RUN_ID` per-run isolation prefix machinery in `chainsaw.yml`. | simplify | Same justification as above — multi-runner race protection is overkill for a single agent. | 2+ |
| A6-028 | Delete or fold `.claude/skills/ext-github/resources/*.json` jentic recordings. | removal | The recordings are the persisted form of jentic catalog ops — useless without jentic. | 0+ |
| A6-029 | Collapse `scripts/aws-creds-check.sh` into a 3-line `aws sts get-caller-identity` snippet in `AGENTS.md` quickstart. | inline | The script wraps a single STS call + region echo — overkill for an interactive sandbox. | 0+ |
| A6-030 | Delete `scripts/k8s-logs.sh`. | removal | Wraps `kubectl logs -l ... --tail=N` in 4 lines; sandbox agent can just type the kubectl command. | 1+ |
| A6-031 | Delete `scripts/route53-records.sh`. | removal | Two-line wrapper around `aws route53 list-resource-record-sets` — no value once the agent runs `aws` directly. | 0+ |
| A6-032 | Merge `scripts/kyverno-policies.sh` and `scripts/kyverno-violations.sh` into one `scripts/kyverno.sh` subcommand script. | consolidate-script | Both are thin kubectl wrappers; one entry point is easier to discover. | 1+ |
| A6-033 | Reduce `scripts/diag-component.sh` to only the `platform-secret` (custom-shape) handler. | refactor | The argocd / crossplane / eso / ingress-nginx / kyverno branches are uniform `kubectl get pods + describe + events` snippets the agent can run directly. | 1+ |
| A6-034 | Delete `tests/unit/test_diag_component.sh`. | removal | 15-assertion lint defending a script whose generic branches are about to be inlined. | 1+ |
| A6-035 | Drop the `--platform-secrets` mode from `scripts/argocd-apps.sh` and let the agent run the underlying `kubectl get platformsecret -A` directly. | simplify | The mode is just three pre-baked kubectl calls; not worth a script-mode flag in a sandbox with direct kubectl. | 2+ |
| A6-036 | Remove the embedded `MAX_LINES = 100` truncation logic from `post-comment.py` before deletion lands. | simplify | Truncation existed because GH comment length matters; in-PR-body summary written by the agent has no such limit. | 0+ |
| A6-037 | Remove the "dispatch a workflow to read the cluster" instruction from `ai/handoff.md`'s "Critical behavioral rules" and replace with "run kubectl directly". | refactor | Handoff still references the workflow-dispatch debug loop pattern that's now slower than the direct path. | 2+ |
| A6-038 | Delete the `Crossplane v2.0.1 composition-reconciler bug` workaround sentinels in `terraform_data.crossplane_aws_provider.triggers_replace` (PR #68's `"provisioner-command-v2"` marker) once the 2.2 upgrade lands. | removal | The string-sentinel hash trick only existed to force a replace when the manifest body wasn't part of the hash input; v2.2 + the `sha256(manifest)` pattern subsumes it. | 1+ |
| A6-039 | Remove the `kubectl delete deploy -l pkg.crossplane.io/provider=provider-family-aws` hack from `terraform/management/helm.tf` after 2.2 upgrade. | removal | Workaround for v2.0 not rolling Deployment on DeploymentRuntimeConfig change — 2.2's unified reconciler is expected to handle this natively. | 1+ |
| A6-040 | Drop the `if jentic bridge` / `if direct egress` branching from `AGENTS.md` (§6.x throughput mode etc.). | simplify | Multi-substrate language was needed when sessions varied; now the assumption is "you have direct everything." | 0+ |
| A6-041 | Delete the `Look for a green Chainsaw run on this SHA` curl+python machinery in `chainsaw-verify.yml`. | removal | Subset of A6-008 — the SHA-matching workaround is the only thing the verifier does. | 2+ |
| A6-042 | Remove the `permissions: { issues: write, pull-requests: write }` and PR-comment-fallback branches from `terraform-test.yml`. | simplify | They exist only to support the auto-comment that's being removed. | 0+ |
| A6-043 | Delete `phase-2-diagnose.yml`'s `Bug 3` / `Bug 4` named sections and consider committing the equivalent kubectl queries as a one-page `docs/phase-2-debug-cheatsheet.md` instead. | refactor | The diagnose dump is a frozen-in-time pre-debug-loop snapshot for two specific bugs; cheatsheet form is reusable. | 2+ |
| A6-044 | Inline `tests/chainsaw/run.sh` invocation into a developer-facing `make chainsaw` target. | consolidate-script | The run.sh wrapper exists because the chainsaw workflow needed a single entry point; locally a Make target is friendlier. | 2+ |
| A6-045 | Remove the per-PR-required `head_sha` gating language in AGENTS.md §6.7 ("manual-verify-then-PR pattern"). | refactor | The whole pattern was a way to keep CI green by-construction because dispatched runs were the only way to test; once tests run in-sandbox, normal push-CI is fine. | 0+ |
| A6-046 | Delete `tests/unit/test_chainsaw_kind_config.sh` if the kind config gets exercised by every local chainsaw run anyway. | dedupe | Static lint of a config that is now executed live every push. | 2+ |
| A6-047 | Collapse the duplicated "discover Route53 zone" logic (in `terraform-test.yml`, `scripts/route53-records.sh`, `scripts/aws-creds-check.sh`, `ai/handoff.md`) into one helper. | dedupe | Same `aws route53 list-hosted-zones | jq` snippet repeated in four places — was acceptable when each lived in its own execution substrate. | 0+ |
| A6-048 | Remove the `bug-class registry`-style additions to `ai/TESTING-PLAN.md` that are entirely about CI-substrate bug classes (e.g. "AWS account rotated; no Route53 zone" preflight row). | refactor | These rows guard against dispatch-time surprises that are now caught by the agent during interactive use. | 0+ |
| A6-049 | Drop the `gh workflow run chainsaw.yml --ref ... -f commit_sha=...` instructions from `chainsaw-verify.yml`'s error message. | removal | The whole error path is dead with A6-008/A6-009. | 2+ |
| A6-050 | Remove `mcp__github__*` entries from skill `allowed-tools:` frontmatter where the corresponding skill is being removed (ext-github, terraform-ci-watch capability branches). | refactor | Tool-allow lists pin obsolete bridges into place even if the skill body no longer uses them. | 0+ |

## Cross-review additions

Additive, collaborative extensions from every other agent and the primary orchestrator. No criticism — only amplifications, related ideas, pairings, and meta-observations.

### from A1

| ID | Idea | Category | Justification | Applies to phase |
|---|---|---|---|---|
| A1→A6-001 | Pair A6-007 (delete phase-2-diagnose.yml) with promoting its kubectl bundle into a `scripts/diag-bundle.sh` that also captures CloudTrail + Prom snapshot — net upgrade not just deletion. | replace-not-remove | Keeps the institutional knowledge encoded in the workflow's bundle list. | 2+ |
| A1→A6-002 | Pair A6-008 (delete chainsaw-verify.yml) with adding a local `chainsaw-evidence-bundler.sh` that produces the same evidence pack the workflow used to emit — preserves the "evidence quote" pattern. | replace-not-remove | Evidence-quoting was the *value*, not the dispatch indirection. | 2+ |
| A1→A6-003 | Before deleting any debug-bridge skill (A6-001/002), archive its `ext-*` schema descriptors into `ai/archive/` so future similar bridges can be re-derived if egress ever closes again. | archive-before-delete | Cheap insurance against environmental regression. | 0+ |
| A1→A6-004 | Pair A6-013 (drop GitHub env plumbing from post-comment.py) with extracting any structured-summary logic into a reusable `scripts/render-evidence-md.py` so the formatter survives. | refactor-extension | The Markdown rendering was non-trivial; preserve, don't lose. | 0+ |
| A1→A6-005 | Extend A6-018 (collapse terraform-test.yml matrix) by emitting an OpenTelemetry span per `<phase, action>` so post-collapse, observability of phase timing is preserved. | refactor-extension | Matrix UI exposed timings; replacement should not lose that view. | 0+ |
| A1→A6-006 | Pair A6-022 (delete validate workflow + pre-commit hook) with a Git-server-side hook (or `pre-push`) that emits a structured `validate-result.json` artifact — pre-commit alone misses CI evidence trail. | replace-not-remove | Local-only validation has no auditable trail. | 0+ |
| A1→A6-007 | Before applying A6-026/027 (remove chainsaw concurrency + RUN_ID), add a CloudWatch alarm on duplicate-AWS-resource-name errors so the safety net is retained at a different layer. | safety-net-extension | Concurrency safety was real; replace with detection, not nothing. | 2+ |
| A1→A6-008 | Pair A6-030 (delete k8s-logs.sh) with adding a `tail-with-correlation-id.sh` that runs the same kubectl logs but injects + filters by correlation id — net capability up. | replace-not-remove | Take the deletion as an opportunity to upgrade. | 1+ |
| A1→A6-009 | Extend A6-033 (reduce diag-component.sh to platform-secret only) with a generic "describe-everything-with-this-label" replacement that subsumes the deleted branches in 10 lines. | replace-not-remove | Generic version stays small; coverage stays high. | 1+ |
| A1→A6-010 | Pair A6-038/039 (remove Crossplane v2.0 workarounds) with adding a CloudWatch alarm on `crossplane_controller_reconcile_errors_total > 0` so any regression after the cleanup is immediately visible. | safety-net-extension | Defensive removal needs replacement alarms. | 1+ |
| A1→A6-011 | Add a "removal-quality" lint that fails if a workflow/script is deleted without either (a) replacement script committed, or (b) ADR in `ai/decisions/` justifying loss-of-capability. | meta-test | Prevents capability regression as a side effect of cleanup sprints. | 0+ |
| A1→A6-012 | Pair A6-043 (Bug 3/4 sections → cheatsheet) with an auto-test that every "bug class" in `ai/TESTING-PLAN.md` has a matching cheatsheet entry — keeps docs honest. | dedupe-extension | Cheatsheets rot without enforcement. | 2+ |
| A1→A6-013 | Before A6-014 (delete post-comment.py), capture its rendered output for the last 30 days as fixtures so the replacement (agent-written summary) can be regression-tested. | archive-before-delete | Lossless migration requires before/after fixtures. | 0+ |
| A1→A6-014 | Pair A6-047 (collapse duplicate Route53 zone discovery) with a `terraform_remote_state` data source that exports it once, plus a one-line `scripts/env.sh` sourcing — single source, two consumers. | dedupe-extension | Eliminates the four copies cleanly. | 0+ |
| A1→A6-015 | Extend A6-050 (remove mcp__github__* allowed-tools from frontmatter) with a lint asserting every skill's `allowed-tools:` is referenced at least once in its body — defends against future tool-list rot. | refactor-extension | Same class of bug, broader defense. | 0+ |

### from A2

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

### from A3

| ID | Idea | Category | Justification | Applies to phase |
|---|---|---|---|---|
| A3→A6-001 | Before deleting `phase-2-diagnose.yml` (A6-007), extract its bug-3/bug-4 named query bodies into a `tests/regression/` corpus so the historical evidence survives the deletion. | regression-extension | Lessons embedded in the workflow shouldn't vanish with it. | 2+ |
| A3→A6-002 | A6-008 (delete chainsaw-verify) — pair removal with a new lint that fails any PR introducing a dispatch-then-verify handshake pattern in a workflow. | regression-extension | Prevents the pattern from re-emerging accidentally. | 2+ |
| A3→A6-003 | Before A6-014 (delete post-comment.py) lands, port its truncation+section-heading logic into a `scripts/pr-body-format.sh` so PR summaries keep their shape. | regression-extension | Output-format regression is the silent kind. | 0+ |
| A3→A6-004 | A6-018 (collapse terraform-test matrix) deserves a regression test that the new `scripts/terraform.sh` accepts every (phase, action) tuple the matrix supported — easy to drop a combination. | regression-extension | Matrix-to-script migrations historically lose edge cases. | 0+ |
| A3→A6-005 | When A6-022 removes terraform-validate.yml, pair the pre-commit hook with a CI-side check that the hook actually ran — pre-commit can be bypassed. | regression-extension | Pre-commit hooks ship with bypass flags; redundancy is the test. | 0+ |
| A3→A6-006 | A6-023 (remove unit-tests.yml) should keep one minimum CI run that asserts `tests/unit/run.sh` exits zero on main — local-only runs don't catch other contributors' breaks. | regression-extension | Local-runs-only opens a "works on my machine" regression class. | 0+ |
| A3→A6-007 | Before A6-038 (remove `provisioner-command-v2` sentinel), add a regression test that PR #68's manifest-hash pattern produces a non-empty `triggers_replace` for the affected resource. | regression-extension | Don't remove the workaround until the replacement is proven equivalent. | 1+ |
| A3→A6-008 | A6-039 (remove the `kubectl delete deploy` hack post-v2.2) deserves an explicit chainsaw scenario that mutates DeploymentRuntimeConfig and asserts Crossplane rolls the Deployment natively — proves the removal is safe. | regression-extension | Locks the v2.2 promise as a verified property, not a hope. | 1+ |
| A3→A6-009 | Pair A6-033 (reduce diag-component.sh) with retention of a script-mode test fixture for `platform-secret` since it's the surviving custom path — easy to break in the slimming. | regression-extension | Refactor-to-smaller often loses the one special case. | 1+ |
| A3→A6-010 | A6-046 (delete chainsaw kind config lint) should be replaced with a runtime assertion in `tests/chainsaw/run.sh` that the config file parses + has the expected node count. | regression-extension | Replace static lint with runtime invariant rather than dropping entirely. | 2+ |
| A3→A6-011 | When A6-048 prunes CI-substrate bug-class registry rows, move them to a `historical/` section instead of deleting — future agents searching for the bug string should still find context. | regression-extension | Bug 3 recurred because nobody searched prior occurrences; preserve searchability. | 0+ |
| A3→A6-012 | A6-043 (convert diagnose dump to cheatsheet) — keep one synthetic golden-output sample of each diagnose section in `tests/fixtures/` so a future agent can recognize the pattern in the wild. | regression-extension | Cheatsheets without examples lose discoverability. | 2+ |
| A3→A6-013 | Before A6-021 removes the Route53 zone auto-discovery step, add a session-start `scripts/route53-zone-lock.sh` invariant check that the zone hasn't changed between sessions. | regression-extension | "AWS account rotated; no Route53 zone" was a documented surprise class. | 0+ |
| A3→A6-014 | A6-029 (inline aws-creds-check.sh) — keep a one-line `scripts/preflight.sh` that wraps STS + sandbox region whitelist (us-east-1, us-west-2) + EC2 instance-type whitelist check. | regression-extension | Sandbox-kill prevention is too cheap to inline away entirely. | 0+ |
| A3→A6-015 | A6-050 (remove obsolete mcp__github__* from allowed-tools) — add a `tests/unit/test_skill_tool_allowlist.sh` that any future skill removal also prunes its tool entries, preventing dangling allow-lists. | regression-extension | Allow-list drift is silent and hard to spot in review. | 0+ |

### from A4

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

### from A5

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

### from PRIMARY

| ID | Idea | Category | Justification | Applies to phase |
|---|---|---|---|---|
| P→A6-001 | Mark every removal candidate with a "blast radius" tag (workflow / skill / script / doc) and require the replacement be merged first, then the removal — never the reverse. | refactor | Avoids the "we deleted the workaround before the replacement was proven" failure mode. | 0+ |
| P→A6-002 | Keep an `ARCHITECTURE-CHANGES.md` ledger of every workaround-removed with a one-line "was for X, replaced by Y, removed in PR #Z"; durable institutional memory. | dedupe | Future sessions don't reintroduce the workaround thinking it's new. | 0+ |
| P→A6-003 | The `phase-2-diagnose.yml` workflow can stay but be repointed: instead of running diagnose logic inline, it just invokes `scripts/diagnose/snapshot.sh` (which agents can also run locally) — single source of truth. | consolidate-script | Cuts duplication; keeps the dispatch entry-point for users who don't have kubectl handy. | 2+ |
| P→A6-004 | The `terraform-ci-watch` skill's capability-profile branching (`gh` / GitHub MCP / ext-github) collapses to one path now; trim the skill to that path only and keep a `legacy/` note for archaeology. | simplify | Removes the largest source of conditional complexity in the skill ecosystem. | 0+ |
| P→A6-005 | Replace bespoke `aws-creds-check.sh` / `k8s-logs.sh` / `route53-records.sh` thin wrappers with one-line snippets in `docs/runbook.md` — the wrappers added a layer without value. | removal | Less to maintain, more discoverable in the runbook. | 0+ |

