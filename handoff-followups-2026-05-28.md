# Handoff — follow-ups from the 2026-05-28 PR #110–#115 merge session

**Repo**: lago-morph/k8-platform
**Date**: 2026-05-28
**Predecessor session merged**: #110, #112, #115, #111, #113, #114 (in that order).

Wait for explicit user direction before starting work. Read `AGENTS.md` first.

---

## What this handoff is for

The PR #111 chainsaw fix took four iterations to land green. Each round
peeled off one bug class while masking the next: 3-condition assert →
`set -o pipefail` under `/bin/sh` → `kubectl -n $namespace` mismatch
→ composition-base mutation overridden by a XR patch. Every one of
those bug classes has either an existing static check that wasn't
wired into the right gate, or a documented helper whose trigger never
fires in the agent-initiated dispatch path.

This file lists the concrete follow-up tasks and includes a full
audit of every helper / script / skill added in the last several days,
classified by whether it is **automatically used** (fires without the
agent having to remember it) or merely **advertised** (exists, is
documented, fires only if the agent looks for it).

The point of the audit is to convert the second class into the first.

---

## Section 1 — Concrete follow-up tasks

### Task 1 — Close the unit-test CI wiring gap

`.github/workflows/unit-tests.yml` is per-step (not a single
`tests/unit/run.sh` call). 17 of the 39 tests listed in `run.sh` are
missing from the workflow, so they only run when an operator types
`tests/unit/run.sh` locally. Among them: the two enforcers whose
absence directly caused this session's pain
(`test_chainsaw_script_shell_portable.sh`,
`test_chainsaw_xr_conditions_complete.sh`).

Full list of tests in `run.sh` not in `unit-tests.yml`:

- `test_chainsaw_assert_references_golden.sh`
- `test_chainsaw_golden_files_present.sh`
- `test_chainsaw_script_shell_portable.sh`
- `test_chainsaw_tag_chars.sh`
- `test_chainsaw_xr_conditions_complete.sh`
- `test_composition_string_transform_type.sh`
- `test_crossplane_trace.sh`
- `test_golden_no_volatile_fields.sh`
- `test_golden_region_uses_binding.sh`
- `test_integration_scripts_strict_mode.sh`
- `test_irsa_trust_validator.sh`
- `test_platform_cluster_composition.sh`
- `test_platform_cluster_xrd.sh`
- `test_runbook_apply_zero_resources.sh`
- `test_shell_readonly_var_assignment.sh`
- `test_wait_for_claim.sh`
- `test_whereami.sh`

**Recommended fix**: append a final `- name: run.sh catch-all` step
that invokes `tests/unit/run.sh` itself. Avoids drift between
`run.sh` and `unit-tests.yml` going forward — every test added to
`run.sh` is automatically gated. The downside (per the comment in
`unit-tests.yml`) is that individual failures aren't separately
diagnosable in the Actions UI; the trade-off is acceptable for the
tests on the list above since none of them are flaky.

**Alternative**: explicitly add each missing test as its own
per-step entry. Higher maintenance cost; preserves Actions-UI clarity.

### Task 2 — Make `scripts/pre-chainsaw-audit.sh` fire on agent-initiated dispatches

The audit script exists at `scripts/pre-chainsaw-audit.sh`. It
encodes six static checks (em-dash in tags, bash-isms in chainsaw
scripts, 3-condition asserts, `($namespace)` literals, golden
namespace defaults, golden-vs-scenario description drift) — checks
A through F. It is the implementation of the `pre-dispatch-static-audit`
skill and is mandated by AGENTS.md §6.13.

Running this audit before any of this session's four chainsaw
dispatches would have caught checks B (bash-isms) and C (3-condition
assert) in one pass. The other two rounds (kubectl namespace; mutation
target) are outside its current coverage but are similar bug classes
that could be added.

It did not fire this session because:

1. The skill's trigger phrases are user-facing
   ("dispatch chainsaw", "kick off chainsaw"). An agent that issues
   `mcp__*__execute` against `chainsaw.yml` directly does not
   produce text that matches these triggers.
2. AGENTS.md §6.13 is prose-only — no hook enforces it.
3. The session-start checklist re-reads `AGENTS.md` but the working
   context doesn't surface §6.13 at dispatch time.

**Recommended fix (pick one):**

- **Hard wiring (preferred):** add a `PreToolUse` hook in
  `.claude/settings.json` matching the `mcp__*__execute` tool and
  scanning the params for `chainsaw.yml`; if matched, run
  `scripts/pre-chainsaw-audit.sh` and block on non-zero exit. See
  the `update-config` skill for the settings.json shape.
- **Soft wiring:** tighten the `pre-dispatch-static-audit` skill's
  description to add automatic-trigger language ("**Automatically
  fires before any `mcp__*__execute` call whose `workflow_id` is
  `chainsaw.yml`**"). Cheaper but relies on the agent reading the
  skill catalog on each cycle.

Add a complementary work item: extend `pre-chainsaw-audit.sh` with two
more checks lifted from this session — (g) kubectl `-n "$NAMESPACE"`
in a chainsaw script block when the surrounding `apply:` step uses a
literal namespace, and (h) yq-mutated composition base field that
appears as a `toFieldPath` in the same composition's patch list.
Check (g) is mechanical; check (h) is the runtime-vs-static debate
from this session's chainsaw round 4 — implement only if you want the
pre-commit gate to catch composition-drift premise breakage.

### Task 3 — Investigate the missing chainsaw completion webhook

`mcp__github__subscribe_pr_activity` was active on PR #111 throughout
the session. The verifier-workflow failure events delivered (4 of
them, one per push). The chainsaw completion event for the final SHA
`ef410ac` (the green run) **did not** deliver — the agent only
learned the run was green via a direct `mcp__*__execute` query.

This is either a subscription event-type filter (chainsaw workflow
not in the watched list), an event-loss in the relay, or
intentional (only PR-checks rolling up to the PR's check list, and
the chainsaw run finished after the verify check already settled).

**Recommended fix**: probe with a fresh subscription to a long-running
chainsaw dispatch and observe whether `completed` events arrive. If
they consistently don't, document the gap in AGENTS.md §6.10 and
update the "wait for completion notification" guidance to mandate a
single backup direct-query at expected ETA + 50%.

### Task 4 — Decide handoff-doc retention policy

Three handoff-shaped files now sit at the repo root:
`handoff-recovery.md` (sanitized from #117),
`i-am-a-fucking-idiot.md` (the pre-sanitization version that was
intended to be replaced, not retained), and this file. PR #117's
intent was to sanitize-into-new-file, not duplicate. The original
sanitization rule lives at
`retrospective/2026-05-28-117/AGENTS-MD-1d16f50361-sanitize-into-new-file.md`.

**Recommended fix**: delete `i-am-a-fucking-idiot.md` and decide
whether to delete `handoff-recovery.md` as well (now that the work
it described — PR #111 fix — has landed). Default: delete both,
keeping only the in-flight handoff (this file).

---

## Section 2 — Audit of recently-added helpers

Scope: files authored or substantively updated between 2026-05-22 and
2026-05-28 in `tests/unit/`, `scripts/`, `.claude/skills/`,
`.github/workflows/`, `AGENTS.md`, and `.pre-commit-config.yaml`.

Classification:

- **Auto-used** — fires without the agent having to remember it
  (CI step, pre-commit hook, hard AGENTS rule with mechanical
  enforcement, or skill trigger that fires on the agent's normal
  working text).
- **Advertised** — exists, is documented, has at least one explicit
  reference in AGENTS.md / scripts/README.md / a skill description,
  but only fires if the agent looks for it.
- **Under-advertised** — exists but no trigger / documentation /
  skill reference is positioned where the agent would notice it
  in the relevant workflow.

### 2.1 Helper scripts (`scripts/`)

| Helper | Classification | Trigger / wiring | Gap |
|---|---|---|---|
| `whereami.sh` | Auto-used | AGENTS §8.1 mandates first-command-of-every-session | None |
| `composition-render.sh` | Auto-used | `.pre-commit-config.yaml` (SPEC-S9) | None |
| `irsa_trust_validator.py` | Auto-used | AGENTS §6.3 step 5 of the post-apply bundle | None — but invocation is in prose, not a hook; depends on agent reading §6.3 |
| `wait-for-claim.sh` | Auto-used | AGENTS §6.1; `crossplane-claim-verify` skill | None |
| `crossplane-trace.sh` | Advertised | AGENTS §7; `crossplane-claim-verify` skill | None significant — skill triggers on claim-apply text |
| `fetch-crds-for-kubeconform.sh` | Advertised | `ai/testing-guidelines.md` only | Acceptable — schema regen is intentional manual |
| `diag-component.sh` | Advertised | `ai/TESTING-PLAN.md` bug-to-test matrix references it | No skill, no auto-trigger; fires only when an operator remembers it |
| `argocd-apps.sh` | Advertised | `scripts/README.md` | No skill, no auto-trigger |
| `aws-creds-check.sh` | Advertised | `scripts/README.md`, `ai/TESTING-PLAN.md` as preflight | No skill; multiple retros propose either collapsing into `docs/runbook.md` or promoting to a hard gate — decision pending |
| `pre-chainsaw-audit.sh` | Under-advertised | AGENTS §6.13 + `pre-dispatch-static-audit` skill | Skill triggers don't catch agent-initiated dispatch (see Task 2) |
| `_lib/aws-cli-helpers.sh` | Auto-used | Sourced by `whereami.sh`, `aws-creds-check.sh` | None |
| `_lib/k8s-helpers.sh` | Auto-used | Sourced by `wait-for-claim.sh`, `crossplane-trace.sh` (SPEC-S7+) | None |

### 2.2 Unit tests (`tests/unit/`)

Pivot of the 39 tests in `tests/unit/run.sh`:

- **22 wired into `unit-tests.yml`** (auto-used).
- **17 in `run.sh` only** (advertised in `run.sh` but silently
  unenforced on push). Listed in full in Task 1.

This is by far the largest auto-use gap in the repo. Every PR
authored in the last week added at least one test to `run.sh`; the
workflow per-step list was not kept in sync.

### 2.3 Skills (`.claude/skills/`)

| Skill | Classification | Trigger shape | Gap |
|---|---|---|---|
| `terraform-ci-watch` | Auto-used | AGENTS §7 + skill desc fires on `git push` to Terraform | None |
| `crossplane-claim-verify` | Auto-used | AGENTS §7 + skill desc fires on claim apply | None |
| `ext-github` | Auto-used | Skill desc fires on "dispatch", "trigger CI", "logs" | None |
| `external-api-bridge` | Auto-used | Used by skill-authoring sessions; not a runtime trigger | Acceptable |
| `subagent-prompting` | Advertised | Skill desc says "use whenever you're about to call the Agent tool" — fires reliably | None |
| `in-flight-workflow-tracking` | Advertised | Skill desc covers dispatches, "I'm going to shut down" | Sometimes missed for short-lived dispatches |
| `pre-dispatch-static-audit` | Under-advertised | Skill desc trigger phrases are user-facing only — see Task 2 | Trigger doesn't catch agent-issued dispatch |
| `post-edit-reread-pass` | Advertised | Skill desc triggers on iterate/verify and on long-doc edits | None significant |
| `always-commit-skill-to-repo` | Auto-used | Skill desc mandates pre-git-op invocation | None |
| `self-retrospective` | Advertised | User-typed `/retr…` or end-of-session | None significant |
| `retro-coverage-audit-and-backfill` | Advertised | User-typed phrases | Off-path for normal sessions |
| `tell-me-about-this-repo` | Advertised | User-typed phrases | Off-path for normal sessions |
| `stacked-pr-on-feature-branch` | Advertised | Skill desc fires on "depends on PR" language | None |
| `parallel-subagent-fanout` | Advertised | Skill desc fires on "fan out" / "multiple subagents" | None |
| `autonomous-run` | Auto-used | Trigger language matches unattended / overnight intent | None |
| `github-connection-resilience` | Auto-used | Auto-fires on MCP auth errors | None |

### 2.4 CI workflows

| Workflow | Classification | Notes |
|---|---|---|
| `unit-tests.yml` | Auto-used (with the gap in Task 1) | Push-triggered |
| `terraform-validate.yml` | Auto-used | Push-triggered |
| `terraform-test.yml` | Advertised | `workflow_dispatch` only by design (AGENTS §6.7) |
| `chainsaw.yml` | Advertised | `workflow_dispatch` only; AGENTS §6.7 manual-verify-then-PR contract |
| `chainsaw-verify.yml` | Auto-used | Push-triggered; cheap gate; verified working this session |

### 2.5 AGENTS.md rules added this week

- §6.7 manual-verify-then-PR for heavy CI — auto-used (the contract
  governs `chainsaw.yml` dispatch).
- §6.8 live-admission verification for v2 Crossplane CRD changes —
  advertised; relies on agent reading the rule at the right moment.
- §6.9 read the failure log first — auto-used (the agent's failure-
  diagnosis muscle memory cites it).
- §6.10 no foreground polling — auto-used (PR #115).
- §6.11 / §6.12 — sandbox capability assertions — advertised.
- §6.13 pre-dispatch static audit — under-advertised (see Task 2).
- §8.1 ephemeral test account — auto-used (the `whereami.sh`
  mandate).
- §8.2 re-check environmental preconditions on infra errors —
  advertised; fires on the right error shapes when the agent reads
  the rule.
- §8.3 handoff docs carry factual state only — auto-used (this file
  conforms to it).

---

## Section 3 — Suggested first concrete action

The single highest-value fix is **Task 1** (close the CI wiring gap).
It is mechanical, has no design ambiguity, and unblocks the
enforcement chain for every helper test that has been authored in the
last week. Once the CI gate is in place, **Task 2** (wire
`pre-chainsaw-audit.sh` to fire automatically before agent-initiated
chainsaw dispatches) prevents the iterative chainsaw debug loop from
recurring. Tasks 3 and 4 are smaller cleanup items.

---

## Section 4 — Prompt to invoke this handoff

Paste the block below at the start of the next session:

```
Read handoff-followups-2026-05-28.md and AGENTS.md first. Then work
through Section 1 of the handoff in order — Task 1, then Task 2,
then Tasks 3 and 4 if you have time.

For Task 1: edit .github/workflows/unit-tests.yml to add a final
"run.sh catch-all" step (preferred) OR append the 17 missing per-step
entries (acceptable alternative). Verify locally by running
`tests/unit/run.sh` before pushing.

For Task 2: implement the hard-wiring option — add a PreToolUse hook
in .claude/settings.json that runs scripts/pre-chainsaw-audit.sh
before any mcp__*__execute call targeting workflow_id=chainsaw.yml
and blocks on non-zero exit. Use the update-config skill for the
settings.json shape. Also extend pre-chainsaw-audit.sh with check
(g) from Section 1.

For Tasks 3 and 4: see the handoff.

Branch per AGENTS.md §3: chore/audit-wiring-fixes-2026-05-NN. Open
one PR per Task (stacked if convenient). Do not merge any PR; ask
me before merging.
```
