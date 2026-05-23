# AGENTS.md suggestions — 2026-05-23-36

These are proposed additions to `AGENTS.md` at the repo root. Each
section contains:

1. **Proposed addition** — the exact text to paste.
2. **Why this earns its place in your agents file** — the argument
   for doing it, grounded in something that happened (or nearly
   happened).

Decide each on its own merits. Skip ones that don't apply to your
operating posture; copy-paste the ones that do.

---

## Suggestion 1: Confirm-before-compound default

### Proposed addition

> **§6.5 Confirm before acting on compound prompts.** For any user
> message that contains three or more distinct actions, bundles a
> feature request with a meta-instruction, or crosses more than one
> PR scope, the agent's first response is a structured repeat-back
> of its understanding before any tool calls. The repeat-back lists
> (a) numbered actions in execution order, (b) explicit stopping
> points, (c) flagged ambiguities with intended interpretations,
> (d) any assumptions inferred from context. The agent then waits
> for the user's reply.
>
> The default is **only** skipped when the prompt itself contains
> an explicit opt-out: "do this without confirming", "just do it",
> "skip the recap", "no need to repeat back", or equivalent.
>
> When the user does not reply but instead acts on the environment
> (merges a PR, pushes a commit), the agent may proceed on the
> drafted plan but **must surface the inference** in its next
> message ("merging PR #N looked like a green light, so I'm
> proceeding on…").
>
> *Grounded in: PR #34 / #35 merges on 2026-05-23, where the user
> bypassed two repeat-back drafts by merging in-flight PRs.*

### Why this earns its place in your agents file

In the 2026-05-23 session, two of the three multi-step prompts I
received bundled at least four distinct asks (one bundled six). My
prior default was to interpret and act; the user's prior default
was to either reply or — twice — to merge the in-flight PR as a
signal of approval. The merge signal worked, but it left two
ambiguity questions unanswered (AGENTS.md vs CLAUDE.md; "tear down
phase X" scope). I made reasonable defaults and moved on, but a
less reasonable default could have produced work the user did not
want.

The marginal cost of the rule is small: one structured message at
the start of a compound prompt. The marginal benefit is that
ambiguity is surfaced before the work, not after. The session's
single largest time sink (the "tear down phase X" clarification
round-trip) would have been ~30 seconds shorter with this rule
applied uniformly.

The user explicitly requested this rule during the 2026-05-23
session, with the framing: "turn the default into 'you tell me what
you think I want you to do', instead of the current 'run with it
making assumptions as I go.'"

---

## Suggestion 2: "Tear down phase X" terminology

### Proposed addition

> **§5.1 "Tear down phase X" — precise definition.** When the user
> says "tear down phase X" (or "destroy phase X", "remove phase X",
> equivalent), the scope is exactly:
>
> 1. Delete every Claim that was created from XRDs introduced in
>    phase X. Wait for Crossplane to deprovision the underlying
>    cloud resources (`kubectl wait --for=delete` on each Claim).
> 2. Delete the XRDs / Compositions / supporting manifests
>    introduced in phase X from the cluster.
> 3. Run `terraform destroy` for any Terraform module owned by
>    phase X, in reverse dependency order.
>
> The scope does NOT include:
>
> - Tearing down phase X-1 or anything lower.
> - Touching the management cluster's bootstrap stack (ingress-nginx,
>   ArgoCD, ESO, Crossplane core, ExternalDNS, Kyverno).
> - Deleting state files for phases not being torn down.
>
> If the user wants a broader teardown they will say so
> ("tear down everything", "tear down phase 0 and 1", etc.).
>
> *Grounded in: the 2026-05-23 session's "tear down phase 2"
> ambiguity, which the user resolved as exactly this scope.*

### Why this earns its place in your agents file

I spent a round-trip with the user asking what "tear down phase 2"
meant — whether it included re-running `terraform destroy` on
phase-1 management. The user's answer was clear in retrospect, but
each future agent will run into the same ambiguity if it isn't
encoded. The encoding cost is one section; the recurring
clarification cost is once per future agent that touches phase
teardown.

The rule also has a load-bearing safety property: it explicitly
forbids tearing down anything below the named phase. That property
matches `AGENTS.md §5 invariant 1` (never destroy a phase lower
than the one being worked on) and reinforces it from the
terminology direction.

---

## Suggestion 3: Preflight check before apply-and-verify

### Proposed addition

> **§7.1 Preflight before any apply-and-verify dispatch.** Before
> dispatching `terraform-test.yml` with `action=apply-and-verify`
> on any phase, the agent runs `scripts/preflight-aws-account.sh`
> (or equivalent — STS check + Route53 zone presence + EC2 quota
> headroom). If the script exits non-zero, the agent does not
> dispatch; it escalates to the user with the script's output.
>
> The preflight runs once per session, or whenever AWS credentials
> are known to have rotated. It does not run on `plan` /
> `verify-only` dispatches.
>
> *Grounded in: the 2026-05-23 phase-1 rerun, which failed mid-job
> at "Discover Route53 zone" because the AWS account had been
> rotated to one without a pre-existing public hosted zone. ~10
> minutes lost to dispatch + diagnose.*

### Why this earns its place in your agents file

The CI workflow correctly aborted with a clear message — there was
nothing in the code to fix — but the failure surfaced 90 seconds
into the run, after the bootstrap step had already created a fresh
S3 state bucket. With a one-second preflight, the agent would have
known to escalate to the user before doing any work. The rule's
cost is one shell invocation per session; the benefit is bounded
by the cost of one CI dispatch round.

---

## Suggestion 4: No bitnami charts in the platform stack

### Proposed addition

> **§10.1 No bitnami charts in the platform stack.** When choosing
> a Helm chart for a new component, do not select the bitnami
> variant. Prefer the upstream chart from the project itself
> (e.g. `kubernetes-sigs/external-dns` not `bitnami/external-dns`).
> If the upstream chart does not exist, prefer a well-maintained
> community alternative; document the choice in the PR description.
>
> *Grounded in: the 2026-05-23 phase-1 attempt with
> `bitnami/external-dns:6.31.0`, which hung at helm install for
> >5 minutes with pods stuck in not-Ready due to a value-shape
> mismatch. Upstream chart with simpler values resolved cleanly.
> User policy stated as: "stay away from bitnami for everything".*

### Why this earns its place in your agents file

Bitnami charts have a tendency to layer their own value-naming and
defaults on top of the upstream project's chart, which produces a
maintenance overhead and silent compatibility problems with the
upstream project's docs. The phase-1 failure was concrete: the
bitnami chart's value structure for AWS provider configuration
didn't match what external-dns 0.14.x actually expected, and the
pods went into a wait loop until helm timed out. Switching to the
upstream chart resolved it in one apply.

The rule's marginal cost is approximately zero — picking a chart is
a one-shot decision per component. The benefit is avoiding silent
chart-shape mismatches.

---

## Suggestion 5: Adversarial subagent review whenever new tests are drafted

### Proposed addition

> **Adversarial subagent review of test plans.** Whenever any new
> tests are about to be drafted, or any existing test is about to be
> extended with a new assertion shape, spawn one or more subagents
> with an adversarial-reviewer brief before authoring the tests. The
> trigger is **source-agnostic** — it does not depend on who
> proposed the tests (user, agent, external review, copy-paste from
> another repo). It is a gate on the *act* of drafting tests, not on
> the source.
>
> Applies to: new phases, new components within a phase (new
> `helm_release`, IRSA role, XRD, ingress, IAM policy), standalone
> test additions in stable phases, extensions to existing tests that
> introduce a new assertion shape.
>
> Does NOT apply to: pure refactors, test file moves/renames,
> fixture updates that don't change assertion semantics.
>
> Default subagent type: `general-purpose`. Run two or more in
> parallel for substantial additions; one is acceptable for small
> standalone additions. Brief MUST include five sections: what
> ships, current test plan, known bug-class history (pasted from
> the bug-class registry), the verbatim job statement, declared
> non-goals. Adopt every adversarial suggestion unless declining
> with a one-line PR-description rationale per skipped item.
>
> *Grounded in: the 2026-05-23 phase-1 bring-up that hit seven
> distinct bug classes, each one in a contract the lead agent had
> not explicitly tested for.*

### Why this earns its place in your agents file

The cognitive failure mode is "test the contracts you already
thought of." Bugs hide in the contracts you didn't. The 2026-05-23
phase-1 bring-up surfaced seven distinct bug classes, each one in a
contract the lead agent had not added to the test plan; an
adversarial reviewer attacking the plan before the tests were
written would likely have caught at least four (helm chart key
spelling, IRSA-on-wrong-SA, missing helm_release for an existing
IRSA role, IAM action superset).

The cost is one subagent dispatch per test-drafting episode — a
~3-minute round trip in parallel with the lead agent doing other
work. The benefit is permanent: every test the adversary surfaces
catches a class of bugs that would otherwise reach a 15-minute
apply cycle.

Source-agnostic triggering is important because review-quality
falls off cliff if the discipline depends on who proposed the
tests. A user-proposed test list is not necessarily better than an
agent-proposed one; both benefit from adversarial attack.

---

## Suggestion 6: TDD-on-bug-fix is unconditional

### Proposed addition

> **TDD discipline when fixing bugs.** When the agent finds any
> issue — CI failure, verify mismatch, runtime surprise,
> user-reported bug, anything — the order of operations is:
>
> 1. **Write a test that would have caught the bug.** Pick the test
>    layer closest to the bug's authoring time (e.g. an IAM-policy
>    completeness bug is a unit test, a runtime drift bug is a
>    Kyverno policy, a multi-step AWS flow bug is an integration
>    test). If the bug fits multiple layers, author the test in each.
> 2. **Run the test against the unfixed code.** Confirm it **fails**
>    (red). If the test passes against buggy code, the test does
>    not actually catch the bug — rewrite it before continuing.
> 3. **Implement the fix.**
> 4. **Verify both:** the new test now passes (green), AND the
>    original symptom (CI step, e2e check, etc.) is resolved.
> 5. **Commit the fix and the test together.** The PR diff must
>    show both so reviewers see what would have caught the
>    regression.
>
> Skipping any step is a procedure violation. Applies to every bug,
> including "obvious" ones — those are exactly the silent-failure
> class that tests prevent.
>
> Does **not** apply to pure refactors (no bug, no test) or net-new
> features (those follow the author-tests-alongside-features rule).
>
> *Grounded in: the 2026-05-23 phase-1 bring-up that took 6 fix
> attempts because regressions reappeared in adjacent forms.*

### Why this earns its place in your agents file

Without this rule, the agent's natural impulse on a bug is "find
the cause, fix, move on." That impulse loses the value of the
bug — the regression-catching test that would prevent it next time.
The 2026-05-23 phase-1 cycle paid this cost concretely: bugs 3, 6,
and 7 were all chart-value mismatches in different shapes; the
unit tests added in response to bug 7 would have caught 3 and 6
too if they'd been written then.

The marginal cost of writing the test first is 5–15 minutes; the
marginal value is permanent (every future regression-catching
session benefits). The asymmetry doesn't need defending — it just
needs codifying so the rule is the default rather than a virtuous
exception.

---

## Suggestion 7: Stacked PRs as the default for multi-step work

### Proposed addition

> **Stacked PRs.** When dependent work needs to start before a
> parent PR has merged, stack:
>
> 1. Create the parent PR off `main` as normal.
> 2. From the parent branch, create the child branch.
> 3. Open the child PR with `base = <parent branch>` (not `main`).
> 4. Once the parent merges, GitHub auto-rebases the child to `main`.
>
> Do not wait for a parent to merge before starting the child. State
> the dependency in the child PR's description.
>
> Naming convention for stacks: parent branch reflects the parent's
> purpose; child branches do not need to reference the parent
> (GitHub tracks it via `base`).
>
> *Grounded in: the 2026-05-23 session's multiple stacked PRs
> (#36 → handoff PR → retro PR), which let the user review and
> merge in parallel with the agent finishing the chain.*

### Why this earns its place in your agents file

Without stacked PRs, multi-step work serializes on reviewer
availability — each PR has to merge before the next can be
authored. That turns a one-day delivery into a multi-day one
because the agent sits idle between reviews.

Stacked PRs decouple authoring from merging. The reviewer gets a
clean per-PR diff (each PR contains one logical change), the agent
keeps moving, and GitHub handles the rebase automatically when the
parent merges. The cost is one extra step at PR-open time ("set
base = parent"); the benefit is wall-clock parallelism.

---

## Suggestion 8: Treat helm chart values as a TYPED contract

### Proposed addition

> **§10.2 Treat helm chart `set { name = "..." }` blocks as a
> typed contract.** For every `helm_release` resource in the repo,
> there must be a corresponding `tests/unit/test_helm_render.sh`
> assertion that proves the rendered output meets the contract the
> Terraform code intends. The chart's value schema is not enforced
> by Terraform; the only check is what the unit test asserts.
>
> When adding or modifying a `set` block, add or update the
> matching assertion in the same commit.
>
> *Grounded in: the 2026-05-23 phase-1 strikes 3 (argocd IRSA on
> wrong SA), 6 (bitnami chart values structure), and 7 (argocd
> ingress.hosts vs ingress.hostname) — all three were silent
> chart-key mismatches that produced rendered manifests not
> matching intent. Three distinct strikes for the same bug class.*

### Why this earns its place in your agents file

Three of the seven phase-1 strikes (3, 6, 7) were the same class:
a `set` block whose key path didn't match the chart's value
schema, producing a rendered manifest that compiled fine but
ignored the value. None of these would have been caught by
`terraform plan` or `terraform apply` — they only surface at
runtime when the rendered K8s object behaves wrong. The unit-test
layer was specifically added in PR #34 to address this, but the
discipline of "every `set` block has an assertion" isn't yet
codified anywhere. Codifying it makes the discipline reviewable
in the PR diff.

---

## Suggestion 9: Maintain a bug-class registry

### Proposed addition

> **§6.6 The bug-class registry.** `ai/TESTING-PLAN.md` contains a
> bug-to-test traceability matrix. After each session that
> surfaces a new bug class (defined as a failure not previously
> represented in the matrix), the agent adds a row before the PR
> is marked ready. The row contains: a one-sentence summary, the
> session date, the test layer that would have caught it, and the
> specific test file added.
>
> The matrix is a normative part of the adversarial-subagent brief
> (§6.4 input #3). Missing rows degrade adversarial-review quality
> for future phases.
>
> *Grounded in: the matrix introduced in PR #34's
> `ai/TESTING-PLAN.md`. Without the maintenance discipline it would
> rot within two phases.*

### Why this earns its place in your agents file

The bug-class registry is high-leverage *if* it's kept current —
it's the input to the adversarial-subagent brief and the basis for
the traceability claim in PRs. The registry decays fast if updates
aren't on the critical path of merging; making the update a
PR-readiness check is the cheapest way to keep it useful.

---

## Suggestion 10: Wait=false for charts whose readiness is testable end-to-end

### Proposed addition

> **§10.3 `wait = false` for charts with end-to-end readiness
> checks.** When adding a `helm_release` whose readiness is
> independently testable via either an integration test
> (`tests/integration/`) or an e2e check, set `wait = false` and
> `timeout = 600` on the `helm_release`. Reasoning: a chart that
> blocks Terraform on pod-Ready waits couples the Terraform layer
> to chart implementation detail (image pull, init container,
> webhook reconciliation), producing failure modes that look like
> Terraform timeouts but are actually chart-internal.
>
> `wait = true` (the helm provider default) is the right choice
> only when no downstream test will catch a not-Ready chart and
> Terraform must surface it.
>
> *Grounded in: phase-1 ExternalDNS install hanging on
> `wait = true` for 5 minutes with bitnami chart misconfiguration,
> producing a Terraform timeout that obscured the actual cause.
> Upstream chart with `wait = false` + e2e verify caught the same
> issue in 30 seconds.*

### Why this earns its place in your agents file

The default of `wait = true` is the helm provider's safe choice,
but it coalesces two distinct failure modes (Terraform problem vs
chart problem) into one timeout signal. Once the e2e layer is in
place (which the project has), `wait = false` is strictly better —
the chart install is fast and the verify layer catches the real
runtime concern. The rule prevents new agents from defaulting back
to `wait = true` out of habit.

---

## Suggestion 11: CLAUDE.md stays a pointer; AGENTS.md is canonical

### Proposed addition

> **§1.1 CLAUDE.md is a pointer; AGENTS.md is canonical.** All
> agent instructions live in `AGENTS.md` at the repo root.
> `CLAUDE.md` exists only as a pointer for the Claude Code
> convention, and contains nothing but a one-line reference to
> `AGENTS.md`.
>
> When updating agent instructions: edit `AGENTS.md`; do not
> duplicate content into `CLAUDE.md`.
>
> *Grounded in: PR #35 consolidation, where CLAUDE.md was
> reduced to a pointer to avoid two-files-of-truth drift.*

### Why this earns its place in your agents file

Cross-agent conventions are stabilizing on AGENTS.md as the
canonical location. Keeping two files in sync is a maintenance
hazard the project explicitly chose to avoid. The rule prevents a
future agent from "helpfully" adding instructions back to
CLAUDE.md.
