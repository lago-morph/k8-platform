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
| Chainsaw | for every XRD / Composition added (every scenario inherits the shared catch block — see testing-guidelines §6.4) | `tests/chainsaw/` |

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

### 6.8 Live-admission verification for v2 Crossplane CRD changes

**Dispatch live chainsaw before relying on kubeconform alone for v2
Crossplane manifest changes.** For any PR that migrates Crossplane
manifests across a major API-version boundary (e.g. v1 → v2 group
rename, XRD `apiextensions/v1` → `/v2`, Composition rewrites with new
`providerConfigRef` shapes), dispatch `chainsaw.yml` against the branch
SHA and confirm at least the `xrd-establishes` scenario passes BEFORE
merging.

**Why kubeconform isn't sufficient here.** The static kubeconform JSON
schema is generated from the CRD's `openAPIV3Schema`. The live
admission webhook has additional handler logic that can reject fields
the schema accepts. The 2026-05-26 v1 → v2 migration discovered this
the hard way: `compositeresourcedefinition_v2.json` accepts
`connectionSecretKeys` on a v2 XRD (the field still exists in the v2
CRD for back-compat), but the v2 admission webhook rejects it at apply
time:

```
CompositeResourceDefinition.apiextensions.crossplane.io
"xplatformclusters.platform.k8-platform.io" is invalid: spec:
Invalid value: "object": XR connection secrets aren't supported in
apiextensions.crossplane.io/v2
```

That gap cost a hotfix PR plus two chainsaw iterations after Wave 2
merged. See `docs/decisions/0001-kubeconform-not-sole-gate-for-v2-crd-changes.md`
for the full ADR.

**Operating contract** (specializes §6.7):

1. After kubeconform CI is green, dispatch `chainsaw.yml` against
   `BRANCH` with `commit_sha=$(git rev-parse HEAD)`. Use
   `scenario_filter=""` for full set, or at minimum a filter that
   includes `xrd-establishes`.
2. On failure: fetch the chainsaw stdout via `ext-github`
   `op_c08d23e5bd6966cb` per §10 of `ai/testing-guidelines.md` BEFORE
   forming hypotheses. Common v2 admission-rejection shapes:
   `is invalid: spec: Invalid value: …`, `--for=condition=Offered`
   timeouts (v2 has no claim CRD, so the Offered condition never
   appears), `no matches for kind <V1Kind>` (v1 claim kind in a v2
   cluster).
3. On success: paste the chainsaw run URL into the PR description
   under "§6.7 chainsaw contract".
4. Only then consider the PR ready to merge.

**Schema-pass IS still the necessary first gate** — kubeconform catches
field-structure changes that the schema correctly reflects (the same
2026-05-26 migration caught `vpcConfig[0]` → `vpcConfig` and
`scalingConfig[0]` → `scalingConfig` via kubeconform locally). This
rule supplements kubeconform with a live-admission gate for the
specific class of failures the schema can't express.

### 6.9 Read the failure log first

**Read the failure log first.** "When ANY CI check fails, the first
action is to fetch the job log (e.g., via `ext-github`'s
`download_job_logs` operation, job ID = last path segment of the
check's `details_url`). Do not read the PR description, workflow YAML,
spec, test source, or commit message before reading the log.
Hypotheses formed from indirect sources are guesses; the actual error
is in the workflow stdout."

*Grounded in: session 2026-05-26 Phase 2 — multiple turns speculating
about AWS-side root causes for chainsaw failures when the log
immediately revealed the v1/v2 provider mismatch.*

See `ai/testing-guidelines.md §10` for the full procedure including
§10.1 on verifying environmental preconditions (AWS creds, cluster
reachability, tool availability) before debugging code.

### 6.10 Never foreground-poll a long-running CI run

**Every tool call re-uploads the entire accumulated conversation
context to the model.** A 100K-token session that foreground-polls a
15-minute CI run every 10 seconds spends ~90 × ~100K ≈ **9 million
input tokens** to learn `status: in_progress` repeatedly. The useful
information is the final ~2KB.

**The rule.** When you need to wait for a long-running CI run (any
GitHub Actions workflow, terraform-test, chainsaw, anything that takes
>1 minute):

1. **Dispatch exactly ONE background poll** via `Bash` with
   `run_in_background: true`. The poll loop runs `curl` against the
   GitHub API and exits only when `status=completed`. Example:
   ```bash
   until [ "$(curl -sS "https://api.github.com/repos/$OWNER/$REPO/actions/runs/$RUN_ID" \
       | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))")" = "completed" ]; do
     sleep 60
   done
   ```
   This polling happens **outside** the model loop — zero tokens
   consumed per check.

2. **Do not make any tool call that queries the same run's status
   until the harness delivers the polling background's completion
   notification.** No `mcp__*__execute` status checks. No `date` calls
   "just to keep alive". No `ls /tmp/.../task-output`. The notification
   IS the wake-up signal — wait for it.

3. **One background poll per run.** Do not launch overlapping polls on
   the same run. If you switched branches or context and lost track of
   the original poll, that is acceptable cost — do NOT add a second
   poll and a third on top.

4. **Do parallel-author work in the meantime, if it doesn't depend on
   the running CI.** Prepare the next PR's content, draft the
   run-summary, run local unit tests — anything that produces durable
   on-disk artifacts. But do NOT call the status tool.

*Grounded in: auto-003 chainsaw waits, where I dispatched a correct
background poll AND then proceeded to foreground-poll the same run
~90 times during the wait, re-uploading the full ~100K-token context
on each call. The user called this out twice in one session.*

**The sandbox suspends when idle — back stop the wait when you resume.**
When `mcp__github__subscribe_pr_activity` is active, completion events
for dispatched runs (chainsaw.yml, terraform-test.yml) normally arrive
as `<github-webhook-activity>` envelopes once the workflow run reaches
`completed`. The Claude Code-on-the-web sandbox is suspended after
inactivity; events that arrive while the sandbox is suspended do not
appear as `<github-webhook-activity>` envelopes when the sandbox
resumes. Three data points so far:
- auto-003 PR #111 final-SHA `ef410ac` chainsaw success: not surfaced
  on resume.
- 2026-05-28 PR #125 run `26552671925` (failure conclusion): surfaced
  while the sandbox was still active.
- 2026-05-28 PR #129 run `26555037975` (success conclusion): completed
  during a multi-minute idle period; not surfaced on resume.
This is a sandbox-lifecycle property, NOT a GitHub webhook reliability
claim. The same envelope shape arrives reliably for events that
complete during an active session.

The cheap mitigation: when you resume after an idle period, OR when
you have dispatched a heavy run and **no** webhook event has arrived
by **expected ETA + 50%** (e.g. 22 minutes for chainsaw, whose normal
wall-clock is ~15 min), issue ONE direct `mcp__*__execute` query
against the run id to read its status. ONE. This costs a single tool
call's context, where ETA+50% with no event is roughly the point at
which the run has either landed or is genuinely stuck — either way,
you need to know.

Do NOT begin polling on a regular interval if the first backup query
returns `in_progress`. Either dispatch a new background poll for the
remaining time, or accept the wait will end via webhook OR the next
ETA+50% backup, whichever fires first.

### 6.11 `[Request interrupted by user]` is a hard stop

**When the harness delivers a `[Request interrupted by user]` system
message, do NOT pivot into an adjacent task** ("let me do this small
thing instead", "while I have you"). Stop the current activity, do not
start a new one, and wait for the user's next explicit direction.
Background processes the agent had started prior to the interrupt
should be killed if they continue to consume model context or
registry/API quota. Treat the interrupt the same way a SIGINT from a
terminal would be treated by an interactive program: full halt.

*Grounded in: auto-003 post-retro phase, where `[Request interrupted
by user]` fired twice and the agent both times continued with a small
adjacent task; the user replied "you keep doing things even when I
push stop."*

### 6.12 Don't claim a tool is "unavailable" until you've tried to install or start it

**Before reporting "X is not available in this sandbox" or deferring
work on that basis, attempt the obvious installation or activation
paths:**

1. **Already installed but not at PATH?** `which X`, `ls /usr/bin/X
   /usr/local/bin/X /root/.local/bin/X`.
2. **Daemon installed but stopped?** `systemctl status X`, `service X
   status`, `pgrep X`, `sudo Xd &`.
3. **One-line install available?** `curl -fL <release-url> -o /tmp/X
   && chmod +x /tmp/X`.

Report "unavailable" only after at least one of those attempts has
failed with a concrete error. The wrong shape of "unavailable" claim
is `which X` returning nothing — that's an unanswered question, not
an answer.

*Grounded in: auto-003 post-retro phase, where the agent twice
deferred substantial work ("docker not in sandbox", "kubectl not in
sandbox") that turned out to be wrong on both counts — docker daemon
needed `sudo dockerd &`, kubectl was a one-line curl install. The
user pointed both out.*

### 6.13 Run a pre-dispatch static audit before any long CI dispatch

**Before dispatching a long-running CI workflow** (chainsaw,
terraform-test, integration suite), run a one-pass static audit for
every known bug class the changed files could exhibit. Long CI
iterations cost minutes per round and tend to surface bugs in layers —
one fix unmasks the next. A pre-dispatch audit catches multiple bug
classes in one pass, in seconds.

The canonical audit lives at `scripts/pre-chainsaw-audit.sh` and is
the implementation of the `pre-dispatch-static-audit` skill
(`SKILL-SPEC-3a7d2e9f1c`). Invoke it before every `chainsaw.yml`
dispatch. The audit MUST cover at minimum:

- (a) non-ASCII characters in tag-bound `description:` / `Description:`
  fields (the AWS Resource Groups Tagging service rejects them — see
  §6.8 ADR-0001).
- (b) `set -o pipefail` / `[[ ]]` / other bash-isms in chainsaw
  `script.content:` blocks (chainsaw runs scripts under `/bin/sh`).
- (c) `status.conditions:` array length not equal to 3 on v2 XR
  asserts (v2 carries Synced + Ready + Responsive).
- (d) `($namespace)` literals in `apply.resource.metadata.namespace`
  (chainsaw's pre-substitution validation rejects these as invalid
  RFC 1123 labels).
- (e) golden YAMLs missing `metadata.namespace: default` (chainsaw
  `assert: file:` searches the per-test namespace by default).
- (f) golden-vs-scenario data-value drift on fields the Composition
  propagates (notably `tags.Description`).

Each check is a one-line grep; the full audit runs in seconds.
Skipping it costs ~5-15 minutes per chainsaw iteration per missed bug
class. Fix every FAIL before dispatching; re-run the audit until clean.

*Grounded in: auto-003 PR #111 chainsaw iterations 1-5, each
surfacing a different bug class that a single pre-dispatch audit
would have caught.*

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

### 8.2 Re-check environmental preconditions when CI surfaces infra-level errors

**Re-check environmental preconditions on each rotated account before
diagnosing code failures.** At session start (always, per §8.1
`scripts/whereami.sh`) AND when any CI failure shows infrastructure-
level errors, verify:

1. `aws sts get-caller-identity` succeeds with the expected account.
2. The state bucket for phase 0 exists for the current account:
   `aws s3 ls "s3://k8-platform-tfstate-$(aws sts get-caller-identity --query Account --output text)/"`.
3. The GitHub Actions repo secrets (`AWS_ACCESS_KEY_ID`,
   `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`) match the current account.
   This cannot be verified from the sandbox; if any other precondition
   above fails, secrets are almost certainly stale too — surface to the
   user.

If any precondition fails, the in-repo handoff doc is stale per §8.1
— **DO NOT continue with code-hypothesis debugging.** Stop, document
the rotation, and either rotate the credentials (operator action) or
re-bootstrap from phase 0.

**Failure shapes that trigger this rule** (specialization of
`ai/testing-guidelines.md` §10.1):

- `Error: Unable to find remote state` from terraform (phase 0 state
  doesn't exist on the rotated account).
- `InvalidClientTokenId` / `The security token included in the
  request is invalid` / `403 Forbidden` from STS or any AWS API.
- `connection refused` / `dial tcp: lookup …: no such host` from
  kubectl (cluster torn down or kubeconfig stale).
- Real-AWS chainsaw scenarios timing out at 245s with
  `Ready=False, message: "Unready resources: …"` — same shape as the
  original `00-situation.md` §1 symptom but now on v2.5.0, where that
  bug is fixed. Most likely cause: chainsaw provider can't
  authenticate to AWS because the runner's secrets are stale.

**Why this rule exists separately from §8.1.** §8.1 says "verify with
the live API" at session start. §8.2 says "verify ALSO when these
specific CI symptoms surface mid-session", because rotation can be
discovered partway through a run and the surrounding code-hypothesis
debugging will go nowhere until the precondition is fixed. See
`retrospective/2026-05-26-106.md` for the 2026-05-26 v1→v2 migration
that surfaced this pattern.

### 8.3 Handoff docs carry factual state only

**Handoff docs carry factual state only.** "When writing a handoff
document for a future agent, restrict the content to (a) verified
outcomes with run IDs / SHAs / PR numbers, (b) the exact open work and
the one concrete next action, and (c) brief neutral operating notes. Do
not include emotional commentary about the user, profanity,
self-flagellation about prior mistakes, ranked speculation about what
the user is most likely to ask next, or verbose narrative of how each
past bug was discovered."

*Grounded in: PR #116 handoff `i-am-a-fucking-idiot.md` primed the next
session for defensiveness; PR #117 sanitization (`handoff-recovery.md`)
preserved every verified outcome, PR number, run ID, SHA, and the
exact one-line fix needed for PR #111 at roughly half the line count
by stripping every priming surface.*

See `retrospective/2026-05-28-117/AGENTS-MD-9621828c6c-handoff-docs-factual-state-only.md`
for the per-rule source and full justification.

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
