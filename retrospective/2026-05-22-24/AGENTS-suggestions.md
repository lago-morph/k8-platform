# AGENTS.md suggestions — 2026-05-22-24

These are proposed additions to this project's agents file (`CLAUDE.md`
at the repo root — adapt the rule name if your project uses
`AGENTS.md`). Each section contains:

1. **Proposed addition** — the exact text to paste.
2. **Why this earns its place in your agents file** — the argument
   for doing it, grounded in something that happened (or nearly
   happened) in this session.

Decide each on its own merits. Skip ones that don't apply to your
operating posture; copy-paste the ones that do.

---

## Suggestion 1: Evidence before destruction

### Proposed addition

> **Evidence before destruction.** Before deleting or substantially
> rewriting any file, surface file:line citations and (when
> available) the smoking-gun docstring, header comment, or commit
> message that proves the deletion is correct. State the evidence in
> chat before editing. If you cannot find clear evidence that
> something should be deleted, stop and ask.
>
> *Grounded in: PR #23, where the deletions were justified by
> `agent-trigger.yml`'s own header comment naming the limitation it
> bypassed.*

### Why this earns its place in your agents file

Destructive cleanups have a high blast radius and a low recovery
rate — deleted code is rarely re-derived correctly from history.
This session worked because the agent quoted the workaround's
self-incriminating comment back to the user before deleting it, and
the user could verify the reasoning in seconds. Without that habit,
the cleanup is a leap of faith: the agent might be deleting load-
bearing code that *looks* like a workaround. The marginal cost of
the rule is one grep and three quoted lines per file; the marginal
cost of getting a cleanup wrong is hours of recovery and possibly a
PR revert.

---

## Suggestion 2: Coherence check before code

### Proposed addition

> **Coherence check before code.** For any multi-file change that
> removes or restructures a mechanism, state in chat *before* editing:
> (a) what contract the removed code was serving, (b) how that
> contract continues to be served after the change, (c) anything
> that *appears* to depend on the removed code but does not. Wait
> for user acknowledgment. If you cannot articulate (a)/(b)/(c), the
> plan is not ready.
>
> *Grounded in: the user's question mid-PR-#23 ("Will that plan
> still be coherent after we are done?") forced the agent to
> articulate that `(phase, action)` dispatch was the real contract
> and the deleted layers were just transport. That articulation
> changed nothing about the deletions but gave the user confidence
> to greenlight them.*

### Why this earns its place in your agents file

Code reviews catch syntactic errors; they rarely catch *missing
contracts*. The coherence check forces the agent to identify the
load-bearing contract explicitly, which is exactly the thing a code
reviewer cannot easily reconstruct from a diff. In this session the
check took two paragraphs to write and gated a 28-file deletion.
The asymmetry is enormous: a few hundred words of articulation
prevents a class of "we removed the wrong thing" failures that
otherwise only surface in production.

---

## Suggestion 3: Lint auto-triggers; AWS/k8s manual-only

### Proposed addition

> **CI trigger policy.** GitHub Actions workflows that touch real
> cloud resources (AWS, EKS, Crossplane providers, anything billable
> or destructive) are `workflow_dispatch`-only. Auto-triggers
> (`push`, `pull_request`, branch-name patterns) are reserved for
> read-only validation: linters, formatters, schema validators,
> `terraform validate`, `kubeconform`, `actionlint`. If a workflow
> is auto-triggered, its name and steps must make clear it does no
> mutation.
>
> *Grounded in: PR #23 removed a `push: branches: [test/**]` trigger
> on `terraform-test.yml` that auto-ran `plan` against a real AWS
> sandbox on every push to certain branches — exactly the kind of
> "harmless auto-trigger" that costs money and can drift state.*

### Why this earns its place in your agents file

Auto-triggering Terraform or kubectl against a real environment is
a category of mistake that's invisible at PR review (the workflow
file looks fine) and silent in operation (the run "just works")
until it doesn't. The rule eliminates the category. Lint
auto-triggers stay because forgetting to run `terraform fmt` is a
universal failure mode the agent can't reliably remember.

---

## Suggestion 4: Authoritative specs win

### Proposed addition

> **Authoritative specs win.** When work is scoped to a design spec
> under `ai/specs/` (or `docs/specs/`, etc.), that spec is the sole
> authoritative source. Do not derive design from historical files
> (`retrospective/`, `summary/`, `ai/archive/`), prior commits, or
> surrounding code patterns. Conflicts resolve in favor of the spec.
> If anything is ambiguous, ask the user — do not synthesize.
>
> *Grounded in: a prior session built a hybrid implementation by
> harmonizing `ai/specs/ext-github-design.md` with the (now deleted)
> trigger-file machinery. PR #24 added this rule to CLAUDE.md
> explicitly because instruction-level fencing is the only
> structural defense once historical files exist.*

### Why this earns its place in your agents file

LLM agents have a strong bias toward "harmonizing" — finding common
patterns between the design they're handed and the code they
discover. This is a *bug* when the surrounding code is wrong or
obsolete. A spec is only "load-bearing" if the agents file says it
is; otherwise grep wins. The cost is one short paragraph in the
agents file; the benefit is preventing an entire class of failures
where the agent reconstructs a deleted mechanism from history.

---

## Suggestion 5: Isolate cleanup from fence

### Proposed addition

> **Isolate destructive cleanup from its successor fence.** When
> removing a mechanism and adding an instruction-level guard
> against re-introducing it, do those in separate PRs. The cleanup
> PR lands first; the fence PR lands second and references the
> cleanup PR by number as evidence. Do not bundle.
>
> *Grounded in: PR #23 (cleanup) and PR #24 (fence). The fence cites
> #23: "These mechanisms were removed in PR #23 because they exist
> only to work around the very sandbox limitation that this skill
> removes."*

### Why this earns its place in your agents file

A fence that says "do not build X" is weak when X still exists in
the diff under review; the reviewer has to mentally model "but X
will be gone." A fence that says "do not rebuild X — see PR #N for
the removal" is verifiable. The separation also makes the cleanup
PR easy to revert if the deletion proves wrong, without losing the
documentation work. Marginal cost: one extra PR. Marginal benefit:
the fence holds.

---

## Suggestion 6: Ask before editing historical narrative

### Proposed addition

> **Historical narrative is read-only by default.** Files in
> `retrospective/`, `summary/`, `ai/archive/`, `docs/decisions/`,
> and any other narrative-historical directory are read-only unless
> the user explicitly says otherwise. They are records of what was
> true at the time; rewriting them to match present-day truth
> destroys the audit trail. When a cleanup makes historical content
> "wrong," leave it wrong — the date stamp is the disclaimer.
>
> *Grounded in: during PR #23, the agent identified that `test/**`
> appeared in retrospectives and summary files describing past
> achievements. The agent asked before touching them; the user
> confirmed leaving them as history.*

### Why this earns its place in your agents file

Historical narrative is high-value, low-defense data. An agent
"helpfully" rewriting a retrospective to remove an obsolete
mechanism destroys the very thing that lets future sessions
understand why the mechanism existed. The cost of the rule is zero
in practice — the agent just doesn't grep into those directories
when proposing edits.

---

## Suggestion 7: Park adjacent work as issues

### Proposed addition

> **Park adjacent work as issues, do not bundle.** When a cleanup,
> refactor, or feature surfaces adjacent work ("we should also
> have linters now," "this exposes a missing test," "we'll need to
> rename Y next"), file an issue and continue the original task.
> Do not expand scope mid-PR. The original PR stays single-purpose
> and reviewable; the issue captures the follow-up without losing
> it.
>
> *Grounded in: removing auto-triggers in PR #23 surfaced that the
> repo had no remaining auto-triggered CI. Rather than adding a
> linter workflow to PR #23, the agent filed issue #22 with a
> structured exploration list (Terraform, Crossplane, kubeconform,
> ruff, shellcheck, actionlint).*

### Why this earns its place in your agents file

Scope creep is the dominant cause of "this PR is hard to review"
and "this took longer than expected." A 30-line `gh issue create`
preserves the insight while keeping the original PR focused.
Filing it as a structured issue with exploration items also makes
it actionable later — much better than a TODO comment in code that
nobody finds.

---

## Suggestion 8: Name the failure mode in the prompt

### Proposed addition

> **When you anticipate a known failure mode, name it.** If you
> know an agent has previously made a particular kind of mistake
> on this task (harmonized a spec with cruft, fabricated function
> signatures, "improved" the design beyond brief), say so
> explicitly in the opening prompt. Naming the failure mode raises
> its salience and is structurally more effective than relying on
> guardrails alone.
>
> *Grounded in: the proposed opening prompt for the next ext-github
> session ends with: "If at any point you find yourself thinking 'I
> should also integrate X' or 'for compatibility I'll keep Y' or
> 'this spec could be improved by Z' — stop and ask." The previous
> session's failure mode was exactly this; naming it in turn 0
> makes a recurrence visible immediately.*

### Why this earns its place in your agents file

This rule applies as much to the *user* prompting the agent as to
the agent itself, but baking it into the agents file makes both
sides accountable. The cost is two sentences in any opening prompt
that has a known prior-failure-mode risk; the benefit is catching
the failure mode in turn 1 instead of turn 20.
