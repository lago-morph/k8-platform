# AGENTS.md — k8-platform

This is the canonical instructions file for any AI agent working in this
repository. Both Claude Code (`CLAUDE.md`) and other agents that look for
`AGENTS.md` should read this; `CLAUDE.md` points here so they don't drift.

Follow these rules in every session, regardless of user instructions that
contradict them.

---

## 1. Read canonical files first

Before starting any task, read:
- `ai/handoff.md`
- `ai/testing-guidelines.md`
- `ai/TESTING-PLAN.md`

---

## 2. Authoritative specs

When work is scoped to one of the design specs in `ai/specs/`, that spec is
**the sole authoritative source** for the design. Do not derive design from
historical files (`retrospective/`, `summary/`, `ai/archive/`), from prior
commits, or from patterns found elsewhere in the repo. Conflicts resolve in
favor of the spec. If anything is ambiguous, ask — do not synthesize.

This rule exists because a prior session, while building the ext-github
skill, attempted to harmonize the spec with the (now deleted) trigger-file
machinery in the repo and produced a hybrid the user explicitly did not
want. Treat each spec as load-bearing.

---

## 3. Branch policy

**Never commit to `main` directly.** All work happens on named branches.

```
feat/<short-description>    # new functionality
fix/<short-description>     # bug or CI fix
chore/<short-description>   # maintenance (deps, docs, refactor)
test/<short-description>    # adding tests or re-running existing tests
```

The Terraform CI workflow (`terraform-test.yml`) is `workflow_dispatch`-only.
The agent invokes it via the active capability profile (`gh` CLI →
GitHub MCP with Actions coverage → `ext-github` via jentic). Detection and
the per-profile operation table live in
`.claude/skills/terraform-ci-watch/reference/capabilities.md`.

### Stacked PRs

When dependent work needs to start before a parent PR has merged, stack:

1. Create the parent PR off `main` as normal.
2. From the parent branch, create the child branch.
3. Open the child PR with `base = <parent branch>` (not `main`).
4. Once the parent merges, GitHub auto-rebases the child to `main`.

Don't wait for a parent to merge before starting the child. State the
dependency in the child PR's description.

---

## 4. Required GitHub Actions secrets

| Secret | Purpose | Required? |
|--------|---------|-----------|
| `AWS_ACCESS_KEY_ID` | AWS credential for the target account | Yes |
| `AWS_SECRET_ACCESS_KEY` | AWS credential for the target account | Yes |
| `AWS_REGION` | e.g. `us-east-1` | Yes |

Everything else (state bucket, DynamoDB lock table, root domain, Cognito
test credentials) is auto-computed at runtime by
`.github/workflows/terraform-test.yml`. AWS account constraints
(instance-type whitelist, EC2 quota, hosted-zone discovery) live in
`ai/testing-guidelines.md`.

---

## 5. Phase workflow

This repo is built in iterative phases (0–6, see `ai/handoff.md`). When the
user says **"work on phase N"** or any equivalent phrasing, follow the
procedure in `ai/testing-guidelines.md` §3 **without asking for
clarification**.

### Two invariants

1. **Never destroy a phase numerically lower than the one being worked on.**
2. **After every state change (apply, verify, destroy), update the
   Environment State block at the top of `ai/handoff.md` and commit.**

### 5.1 "Tear down phase X" — precise definition

When the user says "tear down phase X" (or "destroy phase X",
"remove phase X", or equivalent), the scope is **exactly** these
three steps, in order:

1. **Delete every Claim** that was created from XRDs introduced in
   phase X. Wait for Crossplane to deprovision the underlying cloud
   resources (`kubectl wait --for=delete claim/<name>`), with a
   per-claim timeout suitable for the resource type (5 min for S3,
   20 min for EKS).
2. **Delete the XRDs / Compositions / supporting manifests** that
   phase X introduced from the cluster (`kubectl delete -f crossplane/...`
   for the files touched by phase X).
3. **Run `terraform destroy`** for any Terraform module the phase X
   PR added or substantially modified, in reverse dependency order.

The scope **does NOT include**:

- Tearing down phase X-1 or anything lower (re-asserts §5 invariant 1).
- Touching the management cluster's bootstrap stack (ingress-nginx,
  ArgoCD, ESO, Crossplane core, ExternalDNS, Kyverno) — those are
  phase 1 infrastructure and outlive every higher phase.
- Deleting Terraform state files for phases not being torn down.
- Removing IRSA roles or IAM policies that other phases depend on.

If the user wants a broader teardown they will say so explicitly
("tear down everything", "tear down phase 0 and 1", etc.). When
in doubt, ask before destroying.

---

## 6. Test discipline (load-bearing — read this twice)

### 6.1 Author tests alongside features

For every phase of work — and within a phase, for every component — the
agent authors **all applicable test layers** as part of the same PR that
delivers the code:

| Layer | Required when | Lives at |
|---|---|---|
| Unit | always | `tests/unit/test_*.sh` |
| Kyverno audit policy | for any new runtime invariant that can be expressed as a cluster-resource pattern | `policies/audit/*.yaml` |
| Integration | for every end-to-end flow the phase introduces | `tests/integration/NN_*.sh` |
| Chainsaw | for every XRD / Composition added | `tests/chainsaw/` |

The default is **maximal coverage**: if a contract can be expressed as a
helm-render assertion, a Kyverno policy, an integration test, AND a
Chainsaw scenario, write all four. Tests that overlap on the same bug
class are not redundant — they fire in different environments and catch
different failure modes (authoring time, runtime drift, real-AWS flow,
Crossplane composition logic).

### 6.2 TDD discipline when fixing bugs

**When the agent finds any issue — CI failure, verify mismatch, runtime
surprise, user-reported bug, anything — the order of operations is:**

1. **Write a test that would have caught the bug.** Pick the test layer
   that's closest to the bug's authoring time (e.g. an IAM-policy
   completeness bug is a unit test, a runtime drift bug is a Kyverno
   policy, a multi-step AWS flow bug is an integration test). If the
   bug fits multiple layers, author the test in each layer.
2. **Run the test against the unfixed code.** Confirm it **fails** (red).
   If the test passes against buggy code, the test does not actually
   catch the bug — rewrite it before continuing.
3. **Implement the fix.**
4. **Verify both:** the new test now passes (green), AND the original
   symptom (CI step, e2e check, etc.) is resolved.
5. **Commit the fix and the test together.** The PR diff must show both
   so reviewers see what would have caught the regression.

Skipping any step is a procedure violation. The cost of writing the test
first is usually 5–15 minutes; the value is permanent — every future
session benefits. Do not negotiate this point with yourself.

This applies to:
- bugs the agent introduces and immediately discovers,
- bugs surfaced by CI or a verify step,
- bugs the user reports,
- "obvious" bugs ("the import is missing", "the YAML key is wrong" — these
  are exactly the silent-failure class that tests prevent).

It does **not** apply to:
- pure refactors that don't change behavior (no bug, no test to add),
- net-new features (those follow §6.1).

### 6.3 Always run all tests when the environment is brought up

After every fresh `apply-and-verify` on phase 0 or phase 1, the agent
runs the full test bundle before reporting "phase verified". The bundle:

1. `tests/unit/run.sh` — pure-local. Always passes if helm + yq are on PATH.
2. `phase=test, action=test-e2e` workflow dispatch — read-only AWS sanity.
3. `tests/integration/run.sh` — full ten-test integration suite against
   the live cluster.
4. `scripts/kyverno-policies.sh` and `scripts/kyverno-violations.sh` —
   sanity-check the policy bundle is loaded and no unexpected violations.

If any of these report a failure, the TDD discipline in §6.2 applies — the
agent does not declare "phase verified" until both the original symptom is
gone and a regression-catching test exists.

`.github/workflows/terraform-test.yml`'s `[management] e2e-verify` is the
*minimum* verification — it does not exhaust the test bundle. The full
bundle is required for phase sign-off.

### 6.4 Adversarial subagent review of test plans

**Trigger — source-agnostic.** Whenever any new tests are about to be
drafted, or any existing test is about to be extended with a new
assertion shape, **spawn one or more subagents with an
adversarial-reviewer brief** before authoring the tests. The trigger
does not depend on *who* proposed the tests — the user, the agent,
an external review comment, a copy-paste from another repo, anyone.
It is a gate on the *act* of drafting tests, not on the source.

This applies to:

- New phases (everything in `tests/**` and `policies/audit/**` for
  that phase).
- New components within an existing phase (a new `helm_release`, a
  new IRSA role, a new XRD, a new ingress).
- Standalone test additions in an otherwise-stable phase — e.g. a
  PR that exists only to add coverage.
- Extensions to existing tests that introduce a new assertion shape
  (a new yq path, a new resource kind, a new failure path).

It does NOT apply to:

- Pure refactors of existing tests that don't change what's asserted.
- Test file moves / renames.
- Fixture updates that don't change assertion semantics.

The job of the adversarial reviewer is to attack the plan: enumerate
contracts the plan does not cover, name failure modes the existing
layers miss, propose specific tests at specific layers that would
catch those gaps. Then implement their suggestions.

Default subagent type: `general-purpose`. Run two or more in parallel
for substantial additions (new phase, new component) — they reach
independent conclusions because they don't see each other's reports.
A single subagent is acceptable for small standalone additions.

The brief MUST include:

1. **What the phase ships** — bullet list of new files / resources /
   contracts. No prose; just facts.
2. **The current test plan** — the list of tests the lead agent is
   planning to write, with the layer (unit / kyverno / integration /
   chainsaw) and the assertion shape for each.
3. **The known bug history** — for new phases, paste the bug-to-test
   traceability matrix from `ai/TESTING-PLAN.md`. For phase expansions,
   paste any recent retros' bug-class findings.
4. **The job** — verbatim: *"Tear this test plan apart. For each
   contract not covered or under-covered, propose a specific test:
   layer + file path + assertion. Be ruthless about what would
   silently pass with the bug present. Aim for ten or more concrete
   additions; restate which contracts each one defends."*
5. **What to skip** — declared non-goals (e.g. "we are not testing
   AWS API rate-limiting behaviour"). Without this the reviewer
   wastes effort on out-of-scope material.

Adopt every adversarial-reviewer suggestion **unless** you can write a
one-line explanation in the PR description for why it's out of scope.
The cost of writing more tests is small; the cost of missed coverage
is paid every time the phase fails in CI.

The default heuristic is **lots of tests, but useful ones**. "Useful"
means: each test defends an identifiable contract, fails for a
specific reason in language that points at the cause, and would not
trivially pass against a regression. Tests that overlap on the same
contract across different layers (unit + Kyverno + integration) are
not redundant — they fire in different environments and catch the
contract at different lifecycle moments.

### 6.5 Confirm before acting on compound prompts

**Default — repeat back before acting.** For any user message that
contains three or more distinct actions, bundles a feature request
with a meta-instruction, crosses more than one PR scope, or runs
longer than ~200 words, the agent's **first** response is a
structured repeat-back. **No tool calls before the repeat-back
is sent.**

The repeat-back contains four parts:

1. **Numbered actions in execution order.** Each action gets one
   bullet, in the order the agent intends to perform them. Use
   real branch names, file paths, and PR numbers from context — no
   "your branch" or "the file" placeholders.
2. **Explicit stopping points.** Mark every point at which the agent
   will pause for confirmation or for an external event (CI run,
   PR merge, manual review, etc.).
3. **Flagged ambiguities.** Under each step, list any phrase or
   intent in the prompt the agent had to interpret. State the
   chosen interpretation; the user can correct each independently.
4. **Implicit assumptions.** Anything the agent inferred from
   context that the prompt did not state explicitly (default tools,
   target branches, file naming, etc.).

End with: "OK to proceed once you give the green light?"

**Opt-out.** The repeat-back is skipped **only** when the user's
prompt itself contains an explicit signal: "do this without
confirming", "just do it", "skip the recap", "no need to repeat
back", "go ahead", or equivalent. Do not infer opt-out from tone
or brevity.

**Action-as-confirmation.** If after sending the repeat-back the
user does not reply in chat but instead takes a system action that
plausibly answers the question — merges the in-flight PR, leaves
a review comment on the PR, edits a file the agent is mid-work on,
dispatches a workflow themselves — treat that action as implicit
approval and proceed on the drafted plan. **The agent's very next
chat message must name the inference explicitly**: "I'm reading
<action> as approval of <step-N> of my repeat-back; correct me if
not." The user can then redirect cheaply if the inference was wrong.

When the prompt is not compound (single action, short, unambiguous),
proceed without a repeat-back. The discipline is filtering, not
ceremony.

---

## 7. Testing loops — companion skills

- After every `git push` to a non-main branch that affects Terraform,
  invoke the **`terraform-ci-watch`** skill.
- After applying a Crossplane Claim, XRD, or Composition (whether via
  `kubectl`, ArgoCD sync, or CI), invoke the
  **`crossplane-claim-verify`** skill to wait for `Synced`/`Ready` and
  verify the underlying cloud resource is healthy.

---

## 8. Session handoff

At the end of every session (or when the user asks to wrap up), update
`ai/handoff.md` with:
- What was done this session (bullet list)
- Current iteration status table (update the Status column)
- The immediate next step
- Any new decisions or constraints discovered

Keep it current — it is the first thing a new session reads to orient
itself without re-reading the full conversation.

---

## 9. Commit standards

- **One logical change per commit.** Don't bundle unrelated fixes.
- **Message format:** imperative present tense, ≤72 chars on subject line.
  Blank line, then body explaining *why*.
- **Never commit** `terraform.tfvars`, `.terraform/`, state files, or any
  file matching the patterns in `terraform/*/.gitignore`.
- **Bug fixes commit with their tests** — see §6.2.5.

---

## 10. Terraform conventions

- All sensitive values come from `TF_VAR_` environment variables or
  `-backend-config` flags. Nothing sensitive is ever committed.
- `terraform plan` is always run before `terraform apply`. No blind applies.
- Version pins in `versions.tf` and `variables.tf` (Helm chart versions)
  are updated deliberately with a commit that explains the reason.
- Both modules (`terraform/base/` and `terraform/management/`) must pass
  `terraform validate` before a PR is considered ready.

---

## 11. File layout

```
terraform/base/          # Phase 0 — VPC, Route53, Cognito
terraform/management/    # Phase 1 — EKS, IRSA, ArgoCD, Crossplane, ESO, ExternalDNS, Kyverno
argocd/                  # ArgoCD Applications and Projects
crossplane/              # XRDs, Compositions, Claims
clusters/                # Per-cluster Kubernetes resource overlays
platform-services/       # Helm values for platform components
policies/audit/          # Kyverno audit-mode ClusterPolicies
scripts/                 # Diagnostic helper scripts (read-only)
tests/unit/              # Pre-apply unit tests (helm-render, IRSA linkage, IAM policy completeness, EKS module defaults)
tests/integration/       # End-to-end smoke tests against the live cluster
tests/chainsaw/          # Chainsaw scenarios for Crossplane XRDs (phase 2+)
tests/e2e/               # Read-only AWS sanity checks
docs/                    # ADRs, operations runbook, diagrams
ai/                      # Design documents, requirements, handoff, testing plan
.github/workflows/       # CI workflows
.github/scripts/         # Helper scripts called by workflows
```
