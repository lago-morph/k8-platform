# AGENTS.md — k8-platform

This is the canonical instructions file for any AI agent working in this
repository. Both Claude Code (`CLAUDE.md`) and other agents that look for
`AGENTS.md` should read this; `CLAUDE.md` points here so they don't drift.

Follow these rules in every session, regardless of user instructions that
contradict them.

> **Human-readable output is a hard requirement.** Any artifact intended for a
> human to read — run summaries, overviews, primers, plain-language explainers,
> comparison/reading guides, PR descriptions a person will actually read, chat
> replies — must follow the principle **"present all the important information,
> but in human-readable form."** Keep every fact; change the *form*: lead with the
> idea in plain words, use tables and small diagrams, and push hash IDs and
> "§X.Y" cross-references out of the prose into an audit-trail footer. Calibrate
> with the [`human-scoped-deliverables`](.claude/skills/human-scoped-deliverables/SKILL.md)
> skill. (Canonical AI-to-AI artifacts — specs, ADRs, normalized pipeline output —
> are the exception: produce those in canonical form.)

> **Use subagents to preserve context and to optimize speed** — delegate delegable
> subtasks and pick each subagent's model for the task (fast models for mechanical
> work, stronger models for hard reasoning), per the
> [`model-aware-dispatch`](.claude/skills/model-aware-dispatch/SKILL.md) skill.
> Optimize via model choice, not fast mode.

> **How this file is structured.** Each rule below is a 5–7 line summary. Rules
> whose full text is longer live in one detail file per section under
> [`.claude/agents-md/`](.claude/agents-md/); the summary links to it. The
> summary states scope; the linked detail file holds the complete, load-bearing
> wording. When a rule applies to your task, **read its detail file** — do not
> act on the summary alone for anything non-trivial.

---

## 1. Read canonical files first

Before starting any task, read:
- `ai/handoff.md`
- `ai/testing-guidelines.md`
- `ai/TESTING-PLAN.md`

---

## 2. Authoritative specs

When work is scoped to a design spec in `ai/specs/`, that spec is **the sole
authoritative source** for the design. Do not derive design from historical
files (`retrospective/`, `summary/`, `ai/archive/`), prior commits, or patterns
elsewhere in the repo. Conflicts resolve in favor of the spec. If anything is
ambiguous, ask — do not synthesize a hybrid.

→ Full detail: [`.claude/agents-md/02-authoritative-specs.md`](.claude/agents-md/02-authoritative-specs.md)

---

## 3. Branch policy

**Never commit to `main` directly.** All work happens on named branches:
`feat/`, `fix/`, `chore/`, `test/` + short description. The Terraform CI
workflow (`terraform-test.yml`) is `workflow_dispatch`-only, invoked via the
active capability profile (`gh` → GitHub MCP → `ext-github`). **Stacked PRs:**
when dependent work must start before a parent merges, open the child PR with
`base = <parent branch>` (not `main`); GitHub auto-rebases on parent merge.
Don't wait for the parent.

→ Full detail: [`.claude/agents-md/03-branch-policy.md`](.claude/agents-md/03-branch-policy.md)

---

## 4. Required GitHub Actions secrets

Three repo secrets are required: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
`AWS_REGION`. Everything else (state bucket, lock table, root domain, Cognito
test creds) is auto-computed at runtime by `.github/workflows/terraform-test.yml`.
AWS account constraints (instance-type whitelist, EC2 quota, hosted-zone
discovery) live in `ai/testing-guidelines.md`.

→ Full detail: [`.claude/agents-md/04-github-actions-secrets.md`](.claude/agents-md/04-github-actions-secrets.md)

---

## 5. Phase workflow

This repo is built in iterative phases (0–6, see `ai/handoff.md`). When the user
says **"work on phase N"** (or equivalent), follow `ai/testing-guidelines.md` §3
**without asking for clarification**.

### Two invariants

1. **Never destroy a phase numerically lower than the one being worked on.**
2. **After every state change (apply, verify, destroy), update the Environment
   State block at the top of `ai/handoff.md` and commit.**

### 5.1 "Tear down phase X" — precise definition

"Tear down phase X" means **exactly** three steps, in order: (1) delete every
Claim from phase-X XRDs and wait for deprovision; (2) delete the phase-X
XRDs/Compositions/manifests; (3) `terraform destroy` the modules phase X added,
reverse dependency order. It does **NOT** touch phase X-1 or lower, the
management bootstrap stack, unrelated state files, or shared IRSA/IAM. Broader
teardown requires an explicit user request; when in doubt, ask.

→ Full detail: [`.claude/agents-md/05.1-tear-down-phase-x.md`](.claude/agents-md/05.1-tear-down-phase-x.md)

---

## 6. Test discipline (load-bearing — read this twice)

### 6.1 Author tests alongside features

For every phase — and every component within it — author **all applicable test
layers** in the same PR that delivers the code: unit, kubeconform, Kyverno
audit, integration, chainsaw. The default is **maximal coverage** (overlapping
layers are not redundant — they fire at different lifecycle moments).
**kubeconform is the first schema gate** — fix the field, never add a skip
header. **Composition render dry-run is mandatory** — every new/modified
Composition lands with `render-fixtures/` (input + expected). SPEC-S6/S9.

→ Full detail: [`.claude/agents-md/06.1-author-tests-alongside-features.md`](.claude/agents-md/06.1-author-tests-alongside-features.md)

### 6.2 TDD discipline when fixing bugs

When you find **any** issue (CI failure, verify mismatch, runtime surprise,
user-reported, "obvious" bug): (1) write a test that would have caught it at the
closest layer; (2) run it red against the unfixed code; (3) fix; (4) verify the
test goes green AND the symptom is gone; (5) commit fix + test together.
Skipping a step is a procedure violation. Does **not** apply to pure refactors
or net-new features (those follow §6.1).

→ Full detail: [`.claude/agents-md/06.2-tdd-discipline-bug-fixes.md`](.claude/agents-md/06.2-tdd-discipline-bug-fixes.md)

### 6.3 Always run all tests when the environment is brought up

After every fresh `apply-and-verify` on phase 0/1, run the full bundle before
reporting "phase verified": `tests/unit/run.sh`, `test-e2e` dispatch,
`tests/integration/run.sh`, the Kyverno policy/violation scripts, and
`scripts/irsa_trust_validator.py --all` (must report `0 MISMATCH`). Any failure
triggers §6.2. The workflow's `[management] e2e-verify` is the *minimum*, not
the full bundle.

→ Full detail: [`.claude/agents-md/06.3-run-all-tests-on-bringup.md`](.claude/agents-md/06.3-run-all-tests-on-bringup.md)

### 6.4 Adversarial subagent review of test plans

**Source-agnostic trigger:** whenever new tests are about to be drafted, or an
existing test extended with a new assertion shape, **spawn one or more
adversarial-reviewer subagents first** to attack the plan and propose specific
tests at specific layers. Applies to new phases/components/standalone additions;
not to pure refactors, moves, or semantics-preserving fixture updates. The brief
MUST carry the 5 required parts; run ≥2 in parallel for substantial work; adopt
every suggestion unless you can write a one-line out-of-scope reason.

→ Full detail: [`.claude/agents-md/06.4-adversarial-subagent-review-test-plans.md`](.claude/agents-md/06.4-adversarial-subagent-review-test-plans.md)

### 6.5 Confirm before acting on compound prompts

For any message with ≥3 distinct actions, a feature+meta bundle, multi-PR scope,
or >~200 words, the **first** response is a structured repeat-back (numbered
actions in order; explicit stopping points; flagged ambiguities; implicit
assumptions) — **no tool calls before it**. End with "OK to proceed?" Opt-out
only on an explicit signal ("just do it"). **Action is not confirmation** — a
merge/review/dispatch by the user is not approval; approval comes from chat,
in words.

→ Full detail: [`.claude/agents-md/06.5-confirm-compound-prompts.md`](.claude/agents-md/06.5-confirm-compound-prompts.md)

### 6.6 Throughput-without-attention mode

The user may grant a mode that suspends the §6.5 repeat-back gate: phrases like
"go go go", "ship it", "make assumptions and continue", "stack PRs" flip it ON
until countermanded. While in it: make defensible assumptions (spec → ADR →
handoff → nearest pattern) and state them in the PR; split large work into
stacked PRs (§3). It suspends **only** §6.5 — never §6.1–6.4, §6.3, §9, or
branch policy. Halt-and-ask anyway for out-of-scope destruction, a missing
account constraint, or an unfavored fork.

→ Full detail: [`.claude/agents-md/06.6-throughput-without-attention.md`](.claude/agents-md/06.6-throughput-without-attention.md)

### 6.7 Manual-verify-then-PR for heavy CI workflows

**Heavy CI workflows MUST NOT run on every push** (anything >~2 min, boots a
cluster, or provisions cloud). They are `workflow_dispatch`-only: dispatch
against a specific commit SHA, iterate to green, **then** open the PR. A
<5s push-time verifier gates the PR check on finding a cached green run for that
SHA. Promise: if a PR exists, its HEAD is already green. Current contract:
`chainsaw.yml` ↔ `chainsaw-verify.yml`. (unit-tests / terraform-validate are
light and run on every push.)

→ Full detail: [`.claude/agents-md/06.7-manual-verify-then-pr-heavy-ci.md`](.claude/agents-md/06.7-manual-verify-then-pr-heavy-ci.md)

### 6.8 Live-admission verification for v2 Crossplane CRD changes

For any PR crossing a major Crossplane API-version boundary (v1→v2 group rename,
XRD/Composition rewrites), dispatch `chainsaw.yml` against the branch SHA and
confirm at least `xrd-establishes` passes **before** merging. kubeconform's
static schema isn't sufficient: the live v2 admission webhook rejects fields the
schema accepts (e.g. `connectionSecretKeys` on a v2 XRD). Schema-pass is still
the necessary first gate. ADR-0001.

→ Full detail: [`.claude/agents-md/06.8-live-admission-verify-v2-crd.md`](.claude/agents-md/06.8-live-admission-verify-v2-crd.md)

### 6.9 Read the failure log first

When ANY CI check fails, the first action is to **fetch the job log** (e.g.
`ext-github` `download_job_logs`, job ID = last path segment of the check's
`details_url`). Do not read the PR description, workflow YAML, spec, test
source, or commit message before the log — hypotheses from indirect sources are
guesses; the actual error is in the stdout. See `ai/testing-guidelines.md §10`
(incl. §10.1 on environmental preconditions).

→ Full detail: [`.claude/agents-md/06.9-read-failure-log-first.md`](.claude/agents-md/06.9-read-failure-log-first.md)

### 6.10 Never foreground-poll a long-running CI run

Every tool call re-uploads the whole conversation; foreground-polling a 15-min
run wastes millions of tokens to read `in_progress`. Instead: dispatch **exactly
ONE** background poll (`Bash` `run_in_background`, `until status=completed`), do
no status tool calls until the completion notification, one poll per run, and
author other durable work meanwhile. On resume-after-idle or at **ETA+50%** with
no webhook event, issue **ONE** direct status query — never a polling loop.

→ Full detail: [`.claude/agents-md/06.10-never-foreground-poll-ci.md`](.claude/agents-md/06.10-never-foreground-poll-ci.md)

### 6.11 `[Request interrupted by user]` is a hard stop

When the harness delivers `[Request interrupted by user]`, do NOT pivot to an
adjacent task ("let me do this small thing instead"). Stop the current activity,
start nothing new, and wait for explicit direction. Kill background processes
that keep consuming context or quota. Treat it like a terminal SIGINT: full
halt.

→ Full detail: [`.claude/agents-md/06.11-request-interrupted-hard-stop.md`](.claude/agents-md/06.11-request-interrupted-hard-stop.md)

### 6.12 Don't claim a tool is "unavailable" until you've tried to install or start it

Before reporting "X is not available" or deferring work on that basis, try the
obvious paths: already-installed-but-not-on-PATH (`which`, common bins),
daemon-stopped (`systemctl`/`service`/`pgrep`, `sudo Xd &`), one-line install
(`curl` a release). Report "unavailable" only after a concrete failure. `which X`
returning nothing is an unanswered question, not an answer.

→ Full detail: [`.claude/agents-md/06.12-try-install-before-unavailable.md`](.claude/agents-md/06.12-try-install-before-unavailable.md)

### 6.13 Run a pre-dispatch static audit before any long CI dispatch

Before dispatching a long CI workflow (chainsaw, terraform-test, integration),
run `scripts/pre-chainsaw-audit.sh` (the `pre-dispatch-static-audit` skill) for
every known bug class: non-ASCII in tag `description:`, bash-isms in `/bin/sh`
chainsaw scripts, v2 condition-array length ≠ 3, `($namespace)` literals,
golden YAMLs missing `metadata.namespace`, golden-vs-scenario data drift. Each
check is a one-line grep; fix every FAIL and re-run until clean before
dispatching.

→ Full detail: [`.claude/agents-md/06.13-pre-dispatch-static-audit.md`](.claude/agents-md/06.13-pre-dispatch-static-audit.md)

### 6.14 Use Bash run_in_background, not Monitor, for single-notification waits

For "tell me when X completes", use `Bash` with `run_in_background: true` and an
`until <check>; do sleep N; done` loop that exits on the event. Reserve
`Monitor` for streams of multiple events — a Monitor that just sleeps and ticks
spams chat with useless notifications, doesn't end on your event, and can't be
stopped early.

→ Full detail: [`.claude/agents-md/06.14-bash-bg-not-monitor.md`](.claude/agents-md/06.14-bash-bg-not-monitor.md)

### 6.15 Webhook backup poll at 1.5x expected ETA

When a webhook subscription is the agreed completion channel and 1.5× the
expected ETA has elapsed with no event, do a **single** direct-API status query
as a backup. Subscriptions occasionally drop `workflow_run completed` events
without dropping the surrounding failure events; silence ≠ still-running. One
call at ETA+50% is a fallback, not a polling loop. Specializes §6.10.

→ Full detail: [`.claude/agents-md/06.15-webhook-backup-poll.md`](.claude/agents-md/06.15-webhook-backup-poll.md)

### 6.16 `tests/unit/run.sh` and `.github/workflows/unit-tests.yml` must stay in sync

Every test in `tests/unit/run.sh` MUST also be enumerated in `unit-tests.yml`'s
per-step list, OR the workflow must end with a `run.sh` catch-all. Per-step is
preferred for diagnosability but drifts silently; the catch-all guarantees
coverage. Either is fine; the gap between them is not. A new
`tests/unit/test_*.sh` updates `unit-tests.yml` in the same PR.

→ Full detail: [`.claude/agents-md/06.16-run-sh-unit-tests-yml-sync.md`](.claude/agents-md/06.16-run-sh-unit-tests-yml-sync.md)

### 6.17 Never present a hypothesis as a conclusion

State the strength of every claim: **Observation** (saw it — quote it),
**Exclusion** (ruled out — name the criterion), **Hypothesis** (fits but
unconfirmed — label it), **Conclusion** (positively tested or last-standing
after exhaustive exclusion). "X is the cause" requires positive evidence or full
exclusion; one fits-the-pattern data point is "consistent with X", not "X". A
hypothesis dressed as a conclusion costs the user's trust.

→ Full detail: [`.claude/agents-md/06.17-hypothesis-not-conclusion.md`](.claude/agents-md/06.17-hypothesis-not-conclusion.md)

### 6.18 Never ignore an undiagnosed failure — log to the open-issues register

Every observed failure is either diagnosed this session or recorded in
`docs/open-issues.md` — no silent-skip, no "out of scope so I'll move on", no
unfollowed flaky red. A deferred entry carries: status, verbatim symptom,
evidence so far, labelled hypotheses (§6.17), what's ruled out, next concrete
step, owner. Out-of-scope justifies deferral, never dropping. Flakes get an
entry too. Keep the register tight.

→ Full detail: [`.claude/agents-md/06.18-log-undiagnosed-to-open-issues.md`](.claude/agents-md/06.18-log-undiagnosed-to-open-issues.md)

### 6.19 Never silence cleanup failures with `|| true`

Cleanup/CI steps that depend on succeeding (re-applying state, deleting
resources, restoring config) MUST fail loudly. `|| true` masks the error and
lets contamination cascade into later scenarios. For genuinely best-effort
cleanup, guard explicitly: `[ -f X ] && cmd`, or `if ! cmd; then echo WARN; fi`
so the warning surfaces.

→ Full detail: [`.claude/agents-md/06.19-no-or-true-cleanup-mask.md`](.claude/agents-md/06.19-no-or-true-cleanup-mask.md)

### 6.20 After session resume from suspension, verify status of in-flight dispatches

When the sandbox suspends mid-wait, webhooks arriving during suspension do not
deliver on resume. The first action after resume — before new work, before
answering a question that depends on the outcome — is **one** direct-API query
against each in-flight dispatch's run id. Complements §6.10/§6.15 (active-wait);
this covers the resumed-after-suspension case.

→ Full detail: [`.claude/agents-md/06.20-verify-inflight-after-resume.md`](.claude/agents-md/06.20-verify-inflight-after-resume.md)

### 6.21 Act on the answer to a question you asked

When you ask the user a question (AskUserQuestion or prose) and they answer,
that answer overrides your prior plan. Implement what they chose, not what you
were about to do. Do not re-ask the decision, re-open the options, or pivot back
to your own preferred approach after they picked a different one.

→ Full detail: [`.claude/agents-md/06.21-act-on-the-answer.md`](.claude/agents-md/06.21-act-on-the-answer.md)

### 6.22 Distinguish provisioning from verification in a GitOps repo

In a GitOps repo, do not tell the user to "provision"/"apply" something manually
when ArgoCD/Crossplane/CI converge it from git. Before calling any step a manual
user action, ask whether GitOps or CI already does it; reserve "manual" for
genuine gaps (disabled auto-sync, a Terraform bootstrap you dispatch). When
blocked, name the real blocker — usually verification access, not provisioning.
Drive ArgoCD via the Terraform-output credential (§10.1).

→ Full detail: [`.claude/agents-md/06.22-provisioning-vs-verification.md`](.claude/agents-md/06.22-provisioning-vs-verification.md)

### 6.23 Use the capability you have before asking, in a build session

In a delegated/long build session, exhaust available tools and make a defensible
call before asking. Don't stop on an `AskUserQuestion` for something a tool or
default can resolve — check the capability first (dispatch the probe, try the
install, read the output) per §6.12/§8.5. Reserve user questions for genuine
forks with cost/irreversibility and no defensible default. Asking when the path
was available reads as not-listening.

→ Full detail: [`.claude/agents-md/06.23-use-capability-before-asking.md`](.claude/agents-md/06.23-use-capability-before-asking.md)

### 6.24 Never remove or weaken error checking to work around an undiagnosed error

Disabling a failing check to turn red green is the worst possible "fix" —
always. A failing guardrail (webhook, validation, test, lint, type check,
assertion, readiness gate) is *information*, not an obstacle. When the cause is
unclear the only moves are: fix the actual cause; use a mechanism that works
*with* the check (e.g. clean delete+create vs disabling a hook); or stop,
escalate, and log to `docs/open-issues.md`. Never "skip the test"/`|| true`/
`-k`/comment-out.

→ Full detail: [`.claude/agents-md/06.24-never-weaken-error-checking.md`](.claude/agents-md/06.24-never-weaken-error-checking.md)

### 6.25 Prove a fix with consistent end-to-end tests, not a single signal

Do not call something fixed from one positive observation. Require the real
end-to-end operation to succeed repeatedly with the actual tool — a lone 200 or
one green check is not proof. State explicitly what was tested vs assumed; if the
next call contradicts the first, the state is not-confirmed, not fixed.

→ Full detail: [`.claude/agents-md/06.25-prove-fix-consistent-e2e.md`](.claude/agents-md/06.25-prove-fix-consistent-e2e.md)

### 6.26 Diagnose the cluster through the cloud API when the kube-API is unreachable

When kubectl is blocked, don't declare the problem un-diagnosable — reach the
same facts via the cloud provider API: pod density via ENI/IP counts
(`describe-network-interfaces`), load via CloudWatch, capacity via
`describe-instance-types`, cluster/nodegroup health via the EKS API. Label
cloud-API-derived facts as such; route facts only the kube-API has (pod events,
exact per-node counts) through CI.

→ Full detail: [`.claude/agents-md/06.26-diagnose-via-cloud-api.md`](.claude/agents-md/06.26-diagnose-via-cloud-api.md)

### 6.27 Sandbox egress is a strict-verifying MITM gateway

Sandbox outbound HTTPS passes through a gateway that terminates TLS (leaf signed
by an `Anthropic … Egress Gateway` CA) and strictly verifies the **upstream**
cert. A service you exposed is reachable only if it presents a publicly-trusted
cert whose SAN matches the host; private-CA endpoints (EKS kube-API) and
SAN-mismatched certs 503 and must go via CI. Diagnose with `openssl s_client`:
`verify SAN list` = fixable SAN gap; `unable to get local issuer certificate` =
private CA.

→ Full detail: [`.claude/agents-md/06.27-sandbox-egress-mitm-gateway.md`](.claude/agents-md/06.27-sandbox-egress-mitm-gateway.md)

### 6.28 Honor an explicit stacked-PR request over the harness single-branch directive

When the user explicitly asks for stacked PRs, use the stacked-PR workflow even
if the harness pinned the session to one branch — the owner has given a standing
override (recorded in the `stacked-pr-on-feature-branch` skill), while still
never committing to `main` and keeping all other PR/test discipline.

*Grounded in: auto-012 — agents kept refusing stacked PRs because the harness
says one-branch; the owner granted a standing override.*

### 6.29 Verify a constraint against the repo or owner before encoding it into subagent briefs

Before baking a constraint or premise into briefs that fan out to many subagents
or many review rounds, verify it against the repo and (if owner-policy) the
owner. A false premise propagates across every downstream agent and round and is
expensive to unwind; one `grep`/`ls`/question is trivial by comparison.

*Grounded in: 2026-06-07 — the false "can't edit workflows" premise seeded 3
plans, 14 reviews, and the synthesis before two owner corrections unwound it.*

→ Full detail: [`.claude/agents-md/06.29-verify-premise-before-fanout.md`](.claude/agents-md/06.29-verify-premise-before-fanout.md)

### 6.30 Ground architectural framings in real repo artifacts, not invented distinctions

Do not introduce an architectural distinction or named mechanism with no
referent in the actual repo; verify the artifact exists (the workflow, the
script, the field) before building a plan on it. A phantom distinction survives
until an adversary greps for it — one `ls scripts/` at framing time prevents a
revision pass.

*Grounded in: 2026-06-07 — the "build ≠ CI" split had no referent
(`apply-and-verify` IS a workflow_dispatch job); three round-3 reviewers grepped
and collapsed it.*

→ Full detail: [`.claude/agents-md/06.30-ground-framings-in-artifacts.md`](.claude/agents-md/06.30-ground-framings-in-artifacts.md)

### 6.31 Adversarial and synthesis subagents must verify load-bearing claims against the tree

Brief adversarial and synthesis subagents to verify every load-bearing factual
claim against the actual repo files, not just reason about the document, and name
the files to check. Plan-level facts (a ProviderConfig source, a CRD api
version, an endpoint flag) are routinely wrong and only tree-grounding catches
them.

*Grounded in: 2026-06-07 — tree-grounded reviewers caught `source: IRSA` (not
`InjectedIdentity`), v1-vs-v2 claim-verify, Pipeline MR-kind paths, and the
public spoke; document-only reasoning would have shipped all four wrong.*

→ Full detail: [`.claude/agents-md/06.31-reviewers-verify-against-tree.md`](.claude/agents-md/06.31-reviewers-verify-against-tree.md)

### 6.32 Finalize commits before dispatching a SHA-gated heavy CI run

Do not push further commits after dispatching a heavy CI run that a verifier
gates by exact HEAD SHA; finalize all commits first, then dispatch, or the
cached green run never matches HEAD and the gate stays red on validated work.
Corollary: `mergeable_state: unstable` means mergeable with non-blocking checks
failing/pending — not blocked; check the state before deferring a merge.

*Grounded in: 2026-06-07 — dispatched chainsaw then pushed docs commits, so
chainsaw-verify never matched HEAD; the merge relied on `unstable`, not a green
gate.*

→ Full detail: [`.claude/agents-md/06.32-finalize-before-sha-gated-dispatch.md`](.claude/agents-md/06.32-finalize-before-sha-gated-dispatch.md)

### 6.33 Base a stacked PR on the branch carrying the files it edits

When a stacked PR edits a file, set its base to the branch that already holds the
most recent version of that file — not `main` and not an older sibling. Otherwise
checking out the new branch restores the older file versions; the working tree
looks clean, but a careless `git add -A && commit` ships a silent regression onto
the stack. Pick the base by asking which open branch last touched the files you
are about to edit.

*Grounded in: 2026-06-07 — a feasibility branch based on the run-summary branch
instead of the human-readable branch above it showed committed edits as reverted.*

→ Full detail: [`.claude/agents-md/06.33-stacked-pr-base-selection.md`](.claude/agents-md/06.33-stacked-pr-base-selection.md)

### 6.34 Verify behavior coupled to the build, under the real identity (ADR-0006)

A test must prove the thing *works*, not that a manifest *says* it does. Static
`yq`/`grep` checks are the push/PR floor only — never the oracle. The center of
verification is driving the real controller under its real IRSA identity and
checking the real cloud resource, **on by default and coupled to the build**
(verified when you build it, not on a schedule). Live/cluster work is
`workflow_dispatch`-only; push/PR stays static. Never weaken a behavioral check
down to a green lint. Binding architecture: **ADR-0006**.

→ Full detail: [`docs/decisions/0006-test-architecture-build-coupled-behavioral-verification.md`](docs/decisions/0006-test-architecture-build-coupled-behavioral-verification.md)

### 6.35 Never mark work done on a manually-modified build — verify on a clean build

Do not call a feature complete (or "works"/"proven") if the only verification ran
against a build you hand-modified to make it pass: a paused GitOps auto-sync, a
manual `kubectl apply` of branch manifests, an out-of-band cloud change, a
mid-session policy patch. Those prove the *mechanism*, not the *delivered
artifact*. Completion requires verifying behavior on a build with **no manual
changes** — a clean bring-up from the committed source (GitOps/CI/Terraform),
after a teardown to the relevant phase where feasible. If a clean build cannot be
run yet (e.g. the account is gone), say exactly that and mark the work **"pending
clean-build verification"** — never "done".

### 6.36 A red gate is real — fix the code or fix the test; never re-kick or rationalize

A gating check that is red is a real signal every time. Do **not** "re-kick until
green", do not merge around it, do not narrate why it "doesn't really matter" — an
agent that ignores red half the time has made the gate worthless. Two cases, two
fixes: if the code is wrong, fix the code; if the check is **non-deterministic**
(it flakes red for reasons unrelated to the change — eventual consistency,
ordering, timing), the check itself is the **defect** — make it deterministic (a
bounded poll on the real condition that accepts every valid terminal state) or
move it out of the gating set into a clearly-labeled non-gating tier. Same
coverage, correct tier. A test you'd re-kick rather than trust does not belong in
the gate. (Re-running is legitimate only for a genuinely external infra blip, and
even then the flaky check gets filed and fixed, not normalized.)

---

## 7. Testing loops — companion skills

- After every `git push` to a non-main branch affecting Terraform, invoke the
  **`terraform-ci-watch`** skill.
- After applying a Crossplane Claim, XRD, or Composition (kubectl, ArgoCD, or
  CI), invoke **`crossplane-claim-verify`** to wait for `Synced`/`Ready` and
  confirm the cloud resource is healthy.
- When a claim is stuck, run `scripts/crossplane-trace.sh <kind>/<name>` for a
  one-shot condition walk (`--watch` / `--json` available).

→ Full detail: [`.claude/agents-md/07-testing-loops-companion-skills.md`](.claude/agents-md/07-testing-loops-companion-skills.md)

---

## 8. Session handoff

At the end of every session (or when asked to wrap up), update `ai/handoff.md`
with: what was done (bullets), the current iteration-status table (update the
Status column), the immediate next step, and any new decisions/constraints. Keep
it current — it is the first thing a new session reads to orient itself.

→ Full detail: [`.claude/agents-md/08-session-handoff.md`](.claude/agents-md/08-session-handoff.md)

### 8.1 The AWS test account is ephemeral — NEVER hardcode account-derived values

The AWS account is rotated between sessions. Account ID, derived FQDNs, IRSA
role ARNs, EKS endpoint, OIDC ARN, ACM/Cognito IDs are **not durable** — never
write them into docs, code, commits, PRs, `.tf` files, fixtures, or workflows
(use variables/data sources/secrets). Refer to the account abstractly. Run URLs
and SHAs are fine (durable). Run `scripts/whereami.sh` as the first command of
every session; treat handoff phase-states as belief, not ground truth.

→ Full detail: [`.claude/agents-md/08.1-ephemeral-account-no-hardcode.md`](.claude/agents-md/08.1-ephemeral-account-no-hardcode.md)

### 8.2 Re-check environmental preconditions when CI surfaces infra-level errors

Re-check preconditions both at session start (§8.1 `whereami.sh`) AND when any
CI failure shows infra-level errors: STS identity, the phase-0 state bucket for
the current account, and (surfacing to the user) whether the GHA secrets match.
Trigger shapes: `Unable to find remote state`, `InvalidClientTokenId`/`403`,
kubectl `connection refused`/DNS, 245s chainsaw timeouts. If a precondition
fails the handoff is stale — stop code-hypothesis debugging; document the
rotation.

→ Full detail: [`.claude/agents-md/08.2-recheck-preconditions-on-ci-infra-errors.md`](.claude/agents-md/08.2-recheck-preconditions-on-ci-infra-errors.md)

### 8.3 Handoff docs carry factual state only

A handoff restricts content to (a) verified outcomes with run IDs/SHAs/PR
numbers, (b) the exact open work and the one concrete next action, and (c) brief
neutral operating notes. No emotional commentary about the user, profanity,
self-flagellation, ranked speculation about the next ask, or verbose narrative
of how each past bug was found — those prime the next session for defensiveness.

→ Full detail: [`.claude/agents-md/08.3-handoff-docs-factual-only.md`](.claude/agents-md/08.3-handoff-docs-factual-only.md)

### 8.4 Assume a rotated account is EMPTY until the live API proves otherwise

A new session almost always lands on a freshly-rotated account with no prior
phase work: no state backend, no EKS, no IRSA/ACM/ASM/Cognito — only the single
Route53 hosted zone. Treat **every** phase as `not applied` regardless of the
handoff table until the live API proves otherwise. Before reading a phase's
outputs / dispatching `verify` / calling a phase live, confirm via
`whereami.sh`; if a resource is absent, `apply-and-verify` from scratch — never
`verify` against nothing.

→ Full detail: [`.claude/agents-md/08.4-assume-rotated-account-empty.md`](.claude/agents-md/08.4-assume-rotated-account-empty.md)

### 8.5 Check credentials via Actions — do NOT assume they are stale

§8.1/§8.2/§8.4 are about resource *existence*, not a license to assume the GHA
AWS secrets are invalid. The sandbox has no standing creds but CI does: dispatch
`terraform-test.yml` `phase=test action=test-e2e` (read-only probe) or any
`apply-and-verify` (fails fast on `InvalidClientTokenId`/`403`). When you need
to know whether creds work, **dispatch the probe and read the result** — stale
is a *verified* state, not a default (cf. §6.12).

→ Full detail: [`.claude/agents-md/08.5-check-creds-via-actions.md`](.claude/agents-md/08.5-check-creds-via-actions.md)

### 8.6 Build everything already tested; plan the session while long builds run

The default for a delegated/long session is to **BUILD** every already-tested
phase, not hunt code-only side quests. (1) Start the long pole first — dispatch
the cluster/infra build (~20 min) at session start. (2) Plan and prep the rest
while it runs (no foreground-polling, §6.10). (3) Build what's tested (phases
0-3) and then work live (hub-spoke, `platform-services`, hello app) rather than
re-litigating tested code.

→ Full detail: [`.claude/agents-md/08.6-build-everything-tested.md`](.claude/agents-md/08.6-build-everything-tested.md)

---

## 9. Commit standards

- **One logical change per commit.** Don't bundle unrelated fixes.
- **Message format:** imperative present tense, ≤72 chars on subject line. Blank
  line, then body explaining *why*.
- **Never commit** `terraform.tfvars`, `.terraform/`, state files, or any file
  matching the patterns in `terraform/*/.gitignore`.
- **Bug fixes commit with their tests** — see §6.2.

---

## 10. Terraform conventions

- All sensitive values come from `TF_VAR_` env vars or `-backend-config` flags.
  Nothing sensitive is ever committed.
- `terraform plan` is always run before `terraform apply`. No blind applies.
- Version pins in `versions.tf` / `variables.tf` are updated deliberately with a
  commit that explains the reason.
- Both modules (`terraform/base/`, `terraform/management/`) must pass
  `terraform validate` before a PR is ready.

### 10.1 ArgoCD credentials are a Terraform output (so a session can drive ArgoCD)

When Terraform installs ArgoCD it MUST create a dedicated credential and expose
it — plus the server URL — as Terraform outputs (the sandbox has no standing
kube/ArgoCD creds). Drive ArgoCD by reading `argocd_admin_password` /
`argocd_server_url` from state via a CI workflow, then `argocd login` + `app
sync`/`get`. Do **not** depend on `argocd-initial-admin-secret` or hand the user
a "click Sync" step. Generate via `random_password` + a `terraform_data`
local-exec bcrypt (never `bcrypt()` in a resource arg — perpetual diff).

→ Full detail: [`.claude/agents-md/10.1-argocd-creds-terraform-output.md`](.claude/agents-md/10.1-argocd-creds-terraform-output.md)

---

## 11. File layout

The repository layout (Terraform phases, `crossplane/`, `argocd/`, `clusters/`,
`platform-services/`, `policies/audit/`, `scripts/`, the `tests/` layers,
`docs/`, `ai/`, `.github/`) is documented in full in the detail file.

→ Full detail: [`.claude/agents-md/11-file-layout.md`](.claude/agents-md/11-file-layout.md)

---

## 12. Crossplane conventions

### 12.1 Crossplane v2 has no claims — use "XR" / "composite resource", not "claim"

This repo runs Crossplane v2 (`apiextensions.crossplane.io/v2`, `scope:
Namespaced`): no claim CRD, no claim→XR promotion. `XPlatformSecret` /
`XPlatformCluster` are namespaced XRs applied directly. In commentary, commits,
PRs, and docs say "XR" / "composite resource", never "claim". Some proper names
still contain `claim` (v1-era holdovers) — quoting those verbatim is fine, but
don't let `claim` leak into conceptual descriptions.

→ Full detail: [`.claude/agents-md/12.1-v2-no-claims-xr-terminology.md`](.claude/agents-md/12.1-v2-no-claims-xr-terminology.md)
