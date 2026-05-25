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
| kubeconform | for any YAML touched under `crossplane/`, `argocd/`, `clusters/`, `policies/` | `tests/unit/test_kubeconform_manifests.sh` (SPEC-S6) |
| Kyverno audit policy | for any new runtime invariant that can be expressed as a cluster-resource pattern | `policies/audit/*.yaml` |
| Integration | for every end-to-end flow the phase introduces | `tests/integration/NN_*.sh` (claim waits use `scripts/wait-for-claim.sh`; see SPEC-S7) |
| Chainsaw | for every XRD / Composition added | `tests/chainsaw/` |

**kubeconform is the first line of schema defense.** It runs on every
push and catches the silent-schema-mismatch bug class (Bug 4 PR #61,
Bug 1 PR #74, Kyverno drift PR #64) at commit time instead of at
chainsaw / apply / reconcile time. When kubeconform flags a manifest,
**fix the field — do not add a `# kubeconform-skip` header.** The
allowlist exists for documentation placeholders, not for real
authoring bugs. SPEC-S6 §5.4.

The default is **maximal coverage**: if a contract can be expressed as a
helm-render assertion, a Kyverno policy, an integration test, AND a
Chainsaw scenario, write all four. Tests that overlap on the same bug
class are not redundant — they fire in different environments and catch
different failure modes (authoring time, runtime drift, real-AWS flow,
Crossplane composition logic).

**Composition render dry-run is mandatory at author time** — every new
or modified Composition MUST land with a matching
`crossplane/xrds/<name>/render-fixtures/` directory containing
`input.yaml` and `expected.yaml`. See SPEC-S9
(`ai/brainstorming/specs/SPEC-S9-composition-render-dryrun.md`). The
helper `scripts/composition-render.sh` runs the diff; the pre-commit
hook and `tests/unit/test_composition_render_fixtures.sh` gate every
push.

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
5. `scripts/irsa_trust_validator.py --all` — IRSA trust-policy vs SA
   fleet sweep. Must report `0 MISMATCH` before phase sign-off.

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

**Action-is-not-confirmation.** If after sending the repeat-back the
user does not reply in chat but instead takes a system action —
merges a PR, leaves a review comment, dispatches a workflow, edits
a file — **do not interpret that as approval**. The user is often
reviewing and approving pull requests in parallel with agents doing
work, and may take those actions without even realizing the agent
has asked for approval for something. Approval comes from chat,
explicitly, with words. Continue waiting for that chat reply.

If the wait is unproductive, the agent's options are:
- Continue any orthogonal work that is unaffected by the pending
  question (e.g. drafting documentation for a different concern).
- Send a follow-up chat message reminding the user the question is
  open, naming the specific question.
- Do not proceed on the question itself until the user replies in
  chat with explicit approval, correction, or redirection.

When the prompt is not compound (single action, short, unambiguous),
proceed without a repeat-back. The discipline is filtering, not
ceremony.

### 6.6 Throughput-without-attention mode

The user may explicitly grant a mode in which the §6.5 repeat-back gate is
suspended, the agent makes its own defensible assumptions instead of
asking, and large work is split across stacked PRs so the user can review
asynchronously. This section codifies that mode so it can be reached
without re-explaining each session.

**Trigger.** Any of these phrases (or close paraphrases) flips the mode
ON for the remainder of the session, unless the user later countermands:

- "go go go" / "just go" / "ship it" / "keep working"
- "don't stop for me" / "I'll be away" / "I want throughput without attention"
- "make assumptions and continue" / "you decide" / "use your judgement"
- "stack PRs" / "use PR stacking" / "divide it up how you think best"

The trigger is the *intent*, not exact wording. Once flipped, the mode
persists until the user explicitly reverts ("stop", "wait", "ask me first",
"check with me before X").

**While in the mode, the agent:**

1. **Makes assumptions and proceeds.** Where the prompt is ambiguous,
   pick a defensible default — preferring (in order) the relevant spec
   under `ai/specs/`, an ADR in `docs/decisions/`, the handoff Immediate
   Next Step, then the closest existing pattern in the repo. State the
   assumption inline in the commit or PR description ("Assumed X because
   Y; happy to change in review"). Do not pause to ask. If the user
   disagrees they will edit the PR.

2. **Splits large work into stacked PRs by default.** Any work that
   exceeds one PR's worth of cohesive scope — multiple distinct
   deliverables, multi-component features, anything touching more than
   ~5 directories — gets divided across a stacked sequence per §3
   Stacked PRs. Rules:

   - PR n+1 branches off PR n (`base = <parent branch>`, not `main`).
   - Each PR ships ONE coherent thing — a bug fix, a feature increment,
     one infra layer. The PR title names that one thing.
   - Open every PR as **draft only if** the work is genuinely incomplete
     in this session; otherwise mark ready for review so the user can
     merge asynchronously.
   - Each child PR's body states its dependency on the parent and what
     it adds.

3. **Keeps the next thing dispatched.** While a long-running CI run /
   apply / build is in flight, the agent's job is to author the next
   deliverable, not to babysit the run. PR webhook events arrive
   asynchronously; the agent reacts when they land. Do not idle.

4. **Does NOT waive any other discipline.** Throughput-without-attention
   suspends §6.5 only. It does not suspend:
   - §6.1 / §6.2 — TDD discipline on bug fixes and feature tests.
   - §6.3 — full test bundle after every fresh `apply-and-verify`.
   - §6.4 — adversarial subagents at every test-drafting point. Spawn
     them in parallel and continue authoring while they run; adopt
     suggestions when they return.
   - §9 — commit standards.
   - Branch policy (§3) — no commits to `main`.

**Stop conditions — halt and ask even in throughput mode:**

- A destructive operation outside the user's stated scope is required
  (a teardown they did not request; deleting state; force-pushing `main`).
- An account constraint specified in `ai/testing-guidelines.md §1` is
  missing entirely — the user wants to know about silently-removed
  limits before the agent provisions anything.
- The work reaches a fork where each branch would invalidate the other
  (e.g., choosing between two incompatible XRD schemas) AND neither
  branch is favored by an existing spec / ADR / handoff entry.
- The user countermands the mode in chat.

**When forced to halt:** state the question concisely (one paragraph,
one specific question), then continue any orthogonal work that does not
depend on the answer. Idle waiting is never the right choice in this
mode.

### 6.7 Manual-verify-then-PR for heavy CI workflows

**Heavy CI workflows MUST NOT run on every push.** A heavy workflow is
one that takes more than ~2 minutes, boots a cluster, provisions cloud
resources, or burns runner minutes the agent would otherwise have to
babysit. Examples: `chainsaw.yml` (kind boot + Crossplane + scenarios),
`terraform-test.yml` (15-minute management apply).

Heavy workflows are `workflow_dispatch`-only. The agent runs them
explicitly, against a specific commit SHA, **before** opening the PR.

A lightweight verifier workflow runs on push instead. It queries the
GitHub Actions API for a green run of the heavy workflow against the
same commit SHA, and gates the PR check on finding one. The verifier
is < 5 seconds — `curl + python3`.

**Why:** before this rule was codified, the chainsaw workflow re-ran on
every push during a 2-hour iteration session. The agent fixed install
bugs, config bugs, schema bugs, and binding bugs across ~10 CI failures
on a single PR. The merged-to-main artifact would have been identical
if the agent had dispatched chainsaw locally, fixed each failure, then
opened the PR with the final green run cached on the SHA. The user
would have seen one green PR check instead of ten red ones.

**Operating contract.** When opening a PR that touches paths the heavy
workflow watches:

1. Push the commits to the branch.
2. Dispatch the heavy workflow with the commit SHA as input
   (e.g. `gh workflow run chainsaw.yml --ref <branch> -f commit_sha=$(git rev-parse HEAD)`).
3. Wait for the dispatched run to complete green. If red, iterate
   (fix → push → dispatch again).
4. **Only then** open the PR. The verifier workflow fires on the PR's
   push, finds the cached green run, and reports ✅.

**Promise to the user:** if a PR exists, the heavy tests are already
green for that PR's HEAD SHA. CI red after PR open means the verifier
is doing its job (the agent forgot to dispatch, or pushed new code
after dispatching) — not a flaky test.

**Workflows currently under this contract:**

- `.github/workflows/chainsaw.yml` ↔ `.github/workflows/chainsaw-verify.yml`

**Workflows NOT under this contract** (light + fast):

- `.github/workflows/unit-tests.yml` — runs on every push.
- `.github/workflows/terraform-validate.yml` — runs on every push.

(`terraform-test.yml` is workflow_dispatch-only by design but does not
yet have a verifier; phase apply-and-verify is invoked too rarely to
need one.)

---

## 7. Testing loops — companion skills

- After every `git push` to a non-main branch that affects Terraform,
  invoke the **`terraform-ci-watch`** skill.
- After applying a Crossplane Claim, XRD, or Composition (whether via
  `kubectl`, ArgoCD sync, or CI), invoke the
  **`crossplane-claim-verify`** skill to wait for `Synced`/`Ready` and
  verify the underlying cloud resource is healthy.
- When a claim is stuck or slow, run
  `scripts/crossplane-trace.sh <kind>/<name> [-n <ns>]` for a one-shot
  condition walk down claim → XR → managed-resources → IRSA → atProvider;
  use `--watch` while waiting for reconciliation and `--json` to diff
  snapshots across runs.

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

### 8.1 The AWS test account is ephemeral — NEVER hardcode account-derived values

The AWS account underneath the test environment is rotated between
sessions; the prior account is usually torn down in full before the
next session starts. **The account ID, derived FQDNs, IRSA role ARNs,
EKS cluster endpoint, OIDC provider ARN, ACM cert ARNs, Cognito pool
IDs, and any other account-scoped identifier are NOT durable.**

Do NOT write account-derived values into:
- `ai/handoff.md`, `ai/PLAN.md`, or any other plan/spec/design doc
- code comments, commit messages, PR descriptions, or skill content
- Terraform `.tf` files (use variables / data sources / `local.account_id = data.aws_caller_identity.current.account_id`)
- Test fixtures, scripts, or workflow YAML (read from `${{ secrets.AWS_REGION }}` / `aws sts get-caller-identity`)

Refer to the account abstractly: "the test account", "the account ID (query
via `aws sts get-caller-identity`)", "the `<account-id>.realhandsonlabs.net`
zone". When the next session reads a stale hardcoded ID, it wastes a debug
loop discovering "wait, that resource doesn't exist" before realizing the
doc lied.

Run URLs (`https://github.com/.../actions/runs/N`) and PR/commit SHAs
are fine to cite — those are durable audit-trail artifacts. The line
is: "does this identifier still resolve to a live resource after the
account is rotated?" If no, it's ephemeral and doesn't belong in a
plan or handoff.

Run `scripts/whereami.sh` as the first command of every session; use `--json`
for machine-readable output. This replaces the manual `aws sts get-caller-identity` /
`aws eks list-clusters` sequence and surfaces kubectl context, ArgoCD URL, and
Crossplane version in one call (SPEC-S4).

When picking up a session, the first concrete commands are:
1. `scripts/whereami.sh` — one call for account, region, EKS, zone, kubectl ctx, ArgoCD URL, Crossplane version.
2. Treat the handoff doc's account-level statements (phase 0+1 "applied" vs "needs apply") as the session-author's belief, not ground truth — verify with the live API.

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
scripts/_lib/            # Shared bash helpers sourced by scripts/ executables (SPEC-S7+)
tests/unit/              # Pre-apply unit tests (helm-render, IRSA linkage, IAM policy completeness, EKS module defaults)
tests/integration/       # End-to-end smoke tests against the live cluster
tests/chainsaw/          # Chainsaw scenarios for Crossplane XRDs (phase 2+)
tests/e2e/               # Read-only AWS sanity checks
docs/                    # ADRs, operations runbook, diagrams
ai/                      # Design documents, requirements, handoff, testing plan
.github/workflows/       # CI workflows
.github/scripts/         # Helper scripts called by workflows
```
