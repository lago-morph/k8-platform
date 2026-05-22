# Spec: `decommission-workaround`

## Intent

When an agent operates in a constrained environment (limited sandbox,
missing CLI, restricted API), the repo accumulates workarounds: code
whose only purpose is to bypass the constraint. When the constraint
later lifts — a new tool, an API access change, a sandbox upgrade —
those workarounds become *worse than dead code*: they sit alongside
the new mechanism and invite future sessions to "be helpful" by
merging the two into a hybrid.

This skill drives the cleanup. It identifies workarounds with
evidence, checks that the surrounding system remains coherent after
removal, performs the deletion in one isolated PR, and then fences
the replacement design so the deleted machinery cannot be
reconstructed from historical files.

The skill exists because in this repo, a prior session attempted to
build a new GitHub-API-based dispatch skill and produced a Frankenstein
mashup with the existing `.trigger-action.json` machinery. The user
spent significant effort building the new design; the agent treated
both as authoritative and harmonized them. The fix was structural
removal of the old machinery, not better prompting.

## Trigger

### Direct triggers — activate immediately

- "Remove the workarounds for X" / "we don't need X anymore, clean it up"
- "The sandbox limit is gone, decommission the bypass"
- "Get rid of the hacks we added to work around Y"
- User explicitly names a constraint as resolved and asks for cleanup

### Proactive triggers — offer the skill

- User is about to author a new mechanism that replaces an existing
  workaround (e.g., introducing direct API access while file-commit
  triggers exist).
- A code review surfaces a workaround whose header comment names a
  limitation that has since been resolved.

### Negative triggers — do not activate

- Refactoring for cleanliness with no specific obsolete-by-design
  target. Use a normal refactor flow.
- Removing dead code that was never a workaround (just unused). Use
  a normal deletion.
- When the constraint is *not yet* resolved and the user is asking to
  swap one workaround for another. The skill assumes the replacement
  is real.

## Inputs

- One or more workaround mechanisms named or implied by the user.
- The replacement (a new tool, skill, API access, or workflow) — even
  if it doesn't exist yet.
- Whatever the user told you about which auto-triggered behaviors should
  remain. The skill does not assume "everything becomes manual."

## Outputs

- A survey report (in chat) citing file:line evidence for each
  workaround, with the smoking-gun comment / docstring / header that
  proves it exists to bypass the constraint.
- A coherence statement: how the system continues to work after the
  workarounds are gone.
- **PR #1**: deletion of the workaround machinery. Includes updates to
  any test, doc, or helper that references the deleted code.
- **PR #2** (separate): an instruction-level fence on the replacement
  design — a "non-goals / do not resurrect" block, plus an entry in
  the repo's agents file pinning the replacement spec as
  authoritative.
- An optional follow-up issue for adjacent work that surfaces during
  the cleanup but is intentionally not bundled.

## Workflow

1. **Restate the user's intent** in your own words and wait for
   approval. Do not start any cleanup work until the user signs off.
   Reading and grep are fine; editing is not.

2. **Survey the workarounds.** For each suspected workaround:
   - Find the file and the smoking-gun evidence (usually a comment
     naming the limitation it bypasses, or a docstring that says "to
     work around X").
   - Report file:line and quote the evidence verbatim.
   - Do not skip the smoking-gun step. If you cannot find clear
     evidence that something is a workaround, treat it as legitimate
     code and ask before touching it.

3. **List collateral.** Identify everything that references the
   workaround: helper scripts, unit tests, fixtures, doc sections,
   skill files. Distinguish active references (must update) from
   historical narrative (retrospectives, summaries, archived design
   docs — usually leave alone, but ask).

4. **Coherence check — gated before any code change.** State
   explicitly:
   - What contract the workarounds were serving.
   - How that contract continues to be served after the workarounds
     are gone (typically: the replacement mechanism handles it).
   - Anything in the system that *appears* to depend on the
     workarounds but does not.
   If you cannot articulate coherence, stop and report — the cleanup
   plan is not ready.

5. **Wait for the user's explicit approval** on (3) and (4) before
   editing.

6. **Execute the deletion in one PR.** Use a descriptive branch like
   `chore/remove-<workaround>-workarounds`. The PR title should name
   the constraint that's been lifted, not just the deletions. The PR
   body should reproduce the smoking-gun evidence for the reviewer.
   Run any test suites that exercised the deleted machinery; update
   or delete them as the surface changes.

7. **Fence the replacement in a separate PR.** This is non-negotiable
   — fencing must land *after* the cleanup so it can reference the
   cleanup PR as proof the old machinery is gone (a grep returning
   empty is more persuasive than a doc claiming the machinery is
   absent). The fence has two parts:
   - A "Non-goals — do not build, do not resurrect" block in the
     replacement design doc, naming the deleted machinery explicitly.
   - A new entry in the agents file (`CLAUDE.md`, `AGENTS.md`)
     pinning the replacement spec as authoritative for the
     conflict-resolution rule.

8. **File adjacent issues separately.** If the survey surfaces other
   gaps (e.g., "we have no linters now"), file them as issues, do not
   bundle. The cleanup PR is single-purpose.

## Concrete examples

### Example 1 — the k8-platform session this skill came from

The repo had two CI-triggering mechanisms:

- `.github/workflows/agent-trigger.yml` + `.trigger-action.json`: a
  file-commit shim. Header comment: *"Lets the agent (Claude Code on
  the web) fire CI without workflow_dispatch access."* Smoking gun.
- `terraform-test.yml` with `push: branches: [test/**]`: a branch-name
  auto-trigger. `CLAUDE.md` documented it as the agent's way to fire
  plan-only CI without dispatch.

Both bypassed the same limit (no `workflow_dispatch` from the agent
sandbox). The user was building a new skill that lifts the limit by
giving the agent direct GitHub API access.

The skill produced two PRs:
- **#23**: deleted `agent-trigger.yml`, `parse-trigger.sh`, the
  `.trigger-action.json.example`, the trigger fixtures, the
  `workflow_call` entry point on `terraform-test.yml`, and the
  `test/**` push trigger. Simplified `compute-gates.sh` to drop its
  `event` argument and its push-event branch. Updated docs and the
  unit test that exercised the gates script (18/18 still pass).
- **#24**: added a "Non-goals — do not build, do not resurrect"
  block to `ai/specs/ext-github-design.md` and a new
  "Authoritative specs" section to `CLAUDE.md`. The fence cites PR
  #23 by number as proof.

Adjacent work — adding lint coverage (Terraform fmt, kubeconform,
helm lint, shellcheck, actionlint) — surfaced during the survey
because the cleanup left zero auto-triggered workflows. Filed as
issue #22 instead of bundling.

### Example 2 — hypothetical: removing a polling shim

Suppose an agent's environment previously lacked webhook event
delivery, so a repo built a polling script that ran every minute to
check for new PR comments. The agent's environment is upgraded with
real webhook subscription.

The skill would:
1. Find `scripts/poll-pr-comments.py` and its cron config.
2. Cite the docstring: *"Workaround: we have no event delivery."*
3. List collateral: the systemd unit, the alerting rules that
   suppressed "no new comments" alerts, the docs section explaining
   the 1-minute lag.
4. Coherence: webhook delivery serves the same purpose with no lag.
5. **PR #1**: delete script, systemd unit, alert rules; remove lag
   caveat from docs.
6. **PR #2**: fence the webhook subscription design — non-goals
   include "do not restore polling as a fallback," and the agents
   file pins the webhook design doc as authoritative.

## Anti-patterns

- **Bundling cleanup and fencing in one PR.** The fence cites the
  cleanup as evidence; that's much weaker if both land together.
- **Editing historical narrative (retrospectives, summaries,
  archives) without asking.** Those files are records of what was
  true at the time. Leave them unless explicitly told.
- **Removing workarounds whose smoking gun you can't find.** If the
  code might be legitimate and you're not sure, stop. Cleanup with
  incomplete evidence becomes a regression.
- **Skipping the coherence check.** Workarounds often serve a
  contract that's still needed; the question is whether the
  replacement also serves it. Don't delete and find out.
- **Auto-converting "remove the workaround" into "make everything
  manual."** Some auto-triggers are legitimate (lint, validate). Ask
  what the user wants kept.
- **"Be helpful" by extending the fence to other specs the user
  didn't name.** Stay scoped.

## Acceptance criteria

1. Every deleted file or block has a smoking-gun evidence citation
   in the cleanup PR's body.
2. The cleanup PR's body contains an explicit coherence statement
   ("X was served by Y; after deletion, X is served by Z").
3. The fence PR lands *after* the cleanup PR and references it by
   number.
4. Existing tests pass or were updated; no test is silently deleted
   without justification.
5. Adjacent work surfaced during the survey is captured (issue or
   note), not silently dropped.

## Files this skill creates / modifies

- *(creates)* `chore/remove-<workaround>-workarounds` branch and the
  associated PR — deletes the workaround files, updates collateral.
- *(creates)* `chore/fence-<replacement>-spec` branch and the
  associated PR — adds non-goals block, edits agents file.
- *(creates)* a parking-lot issue for adjacent work, if any surfaced.
- *(modifies)* the replacement design doc — new non-goals section
  near the top, ideally adjacent to required-reading.
- *(modifies)* the agents file — new "authoritative specs" entry
  pinning the replacement.
