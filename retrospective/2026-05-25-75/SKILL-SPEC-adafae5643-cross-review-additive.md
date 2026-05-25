# Spec: `cross-review-additive`

- **ID**: SKILL-SPEC-adafae5643
- **Source retrospective**: ../2026-05-25-75.md

## Intent

After an N-agent parallel brainstorm or implementation-spec round produces N independent artifacts, a cross-review pass — where each agent reviews every other agent's output — multiplies the value of the original output and surfaces cross-cutting connections no single agent saw. This skill orchestrates that pass in **additive-only** mode (extensions, amplifications, pairings, related ideas — never criticism) with **write-contention avoidance** via dedicated per-agent output files, then merges contributions back into the originals mechanically. Proven in PR #73 where 6 cross-review agents added 466 extension entries to 6 original brainstorms (400 ideas) with zero file collisions.

## Trigger

Direct triggers — invoke immediately:

- "Have the agents cross-review each other's work"
- "Run a cross-review round on the brainstorm"
- "Let them comment on each other's output"

Proactive triggers — offer:

- After an N-agent parallel fanout (`parallel-subagent-fanout` skill) completes and produced N independent artifacts.
- The user expresses interest in second-order analysis ("anything they missed?", "what connections exist between these?").

Negative triggers — do NOT invoke for:

- Adversarial review (use `code-review` or §6.4 adversarial-subagent pattern instead).
- Single-agent output (cross-review needs ≥3 reviewers).
- Code review where criticism is the goal (this skill is explicitly NO-criticism).

## Inputs

- An array of N artifact files (typically markdown), one per source agent, with a consistent naming convention (e.g., `A1-debug-tools.md`, `A2-tests.md`, ...).
- Each file has a known table-row structure with durable IDs (e.g., `A1-001`, `A2-001`).
- The user may specify a `from_agent` set if it differs from the source-artifact set (e.g., the primary orchestrator joins the cross-review pool).

## Outputs

- `cross-review-from-<X>.md` per reviewer X — contains X's additions to every other agent's output, structured by `## For <target-file>` sections, each with a pipe-table of one-sentence additions.
- Each addition row carries a durable ID following the convention `<X>→<target>-NNN` (e.g., `A2→A1-001`).
- An inline summary in chat naming the reviewers and addition counts.

## Workflow

1. **Confirm preconditions.** The N original artifacts exist on disk under a known directory. Each has durable IDs in its rows. The user has confirmed the cross-review round should run.
2. **Verify SendMessage is available** (`ToolSearch select:SendMessage`). If not (as in the Pluralsight web sandbox), spawn FRESH subagents for the cross-review round instead of resuming the originals. This is a critical sandbox detail — incorrectly assuming SendMessage is available wastes one round-trip.
3. **Compose the cross-review brief.** Each reviewer X gets: (a) the list of N-1 target files to review, (b) the explicit framing "additive-only — extensions, related ideas, pairings, amplifications, no criticism", (c) the output path `cross-review-from-X.md`, (d) the ID convention `<X>→<target>-NNN`, (e) target counts ("5-15 additions per target file = 25-75 total").
4. **CRITICAL: write-contention avoidance.** Each reviewer writes to ONLY its own `cross-review-from-X.md` file. NEVER have multiple reviewers append to the same target file simultaneously — file locking is not reliable across parallel subagents. The merge happens later.
5. **Dispatch all N reviewers in parallel** via a single message containing N `Agent` tool calls. Use `general-purpose` subagent type; foreground (not background) so completion notifications arrive.
6. **Wait for all N completions.** Track which have arrived; report counts inline as each lands.
7. **Run the merge script.** A Python script reads each `cross-review-from-X.md`, extracts the `## For <target-file>` sections, and appends them under each original file's `## Cross-review additions` heading, labeled `### from X`, `### from Y`, etc. Preserve the standalone files (the user may want both views).
8. **Verify counts.** `grep -cE '^\| (\w+→\w+-|P→\w+-)[0-9]+ \|' <each cross-review file>` to confirm row counts match what each reviewer reported.
9. **Commit.** One commit covering the standalone cross-review files + the merge into the originals.

## Concrete examples

### Example 1: Six-agent brainstorm cross-review (PR #73)

Input: `ai/brainstorming/A1..A6-*.md` (each 50-100 rows). Reviewers: A1, A2, A3, A4, A5, A6, plus the primary orchestrator. Each reviewer writes to `cross-review-from-{A1..A6,primary}.md`.

Per-reviewer brief excerpt:
> Read these five files in ai/brainstorming/: A1-..., A2-..., A3-..., A4-..., A5-.... For each file, append ADDITIVE-ONLY suggestions from the perspective of A6 (removal & refactor lens). No criticism of the source idea itself. Only: extensions, related cruft the idea reminds you could be retired, "this idea also lets us delete X" notes. Everything positive and collaborative. Write a SINGLE file: cross-review-from-A6.md. Aim for 5-15 additions per target file (25-75 total).

Result: 76 + 76 + 70 + 74 + 67 + 70 + 33 = 466 cross-review entries authored across the seven cross-review files. Zero file collisions because each reviewer wrote to a dedicated file. Merge script appended sections into the originals' `## Cross-review additions` blocks.

### Example 2: SendMessage-not-available pivot

When `ToolSearch select:SendMessage` returned no match (Pluralsight web sandbox), the orchestrator spawned six FRESH cross-review subagents via `Agent` instead of attempting to resume the original six. Fresh agents needed full context in their briefs (couldn't rely on memory). The brief was self-contained: "Read these five files... append additions to cross-review-from-X.md."

## Anti-patterns

- **Allowing criticism.** Cross-review is explicitly extension-only. If a reviewer disagrees with a source idea, they do not add a row about it. (Disagreement belongs in a separate adversarial-review pass per AGENTS.md §6.4.)
- **Shared write target.** Multiple reviewers appending to a single target file in parallel will race and lose data. Always per-reviewer dedicated files.
- **Skipping the merge step.** Without merging cross-review back into originals, future readers don't see the extensions unless they specifically open the cross-review files. The merged-into-original view is the consumed view.
- **Free-form references in addition rows.** Every addition row must reference at least one source ID in its prose (e.g., "Extend A1-019 with..."). Without IDs, programmatic reference extraction (for later JSON port) fails.
- **Dispatching reviewers serially.** N-1 wall-clock multiplier wasted. Always one message, N parallel tool calls.

## Acceptance criteria

- [ ] Each reviewer's `cross-review-from-X.md` contains the expected 5-15 additions per target.
- [ ] No file appears in more than one reviewer's write set.
- [ ] 100% of addition rows reference ≥1 source ID inline (regex-checkable).
- [ ] Merge produces a `## Cross-review additions` section under each original with sub-headings `### from X`.
- [ ] Inline summary names each reviewer's addition count + total.

## Files this skill creates / modifies

- `<corpus_dir>/cross-review-from-X.md` per reviewer X — standalone view (preserved permanently).
- `<corpus_dir>/<original>-*.md` — each original gets a `## Cross-review additions` section appended via the merge script.
- `/tmp/merge_crossreview.py` — the merge script; ephemeral but committed alongside if reused.
