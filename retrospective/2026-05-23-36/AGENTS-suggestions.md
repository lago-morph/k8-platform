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

## Suggestion 5: Adversarial subagent review on every new phase

### Proposed addition

(Already landed as `AGENTS.md §6.4` in PR #36. This entry is here
only to make `AGENTS-suggestions.md` complete; no action needed.)

---

## Suggestion 6: TDD-on-bug-fix is unconditional

### Proposed addition

(Already landed as `AGENTS.md §6.2` in PR #35. No action needed.)

---

## Suggestion 7: Stacked PRs as the default for multi-step work

### Proposed addition

(Already landed as `AGENTS.md §3 — Stacked PRs` in PR #35. No
action needed.)

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
