# Spec: `doctrine-impl-preflight`

## Intent

When the user says "do procedure P" and the agent reads a doc that describes P, the agent often assumes — without verifying — that the artifacts P references actually exist. They frequently don't. Doctrine and implementation drift: a doc says the CI workflow exposes inputs `phase` and `action`; the workflow YAML actually only exposes `mode`. The drift is invisible to the agent until it tries to use the missing artifact, which is usually mid-task, after work has already been planned around the false assumption.

This skill is a 60–120 second cross-check that runs at the orient step of any task driven by a procedural doc (testing guidelines, runbook, deployment procedure, ADR with executable steps, etc.). It enumerates the concrete artifacts the doc references — workflow files, scripts, env vars, CLI commands, tools — and spot-checks each against the live repo. The output is a manifest of "doctrine claims X exists" vs "X actually does/doesn't exist," which becomes the agent's first communication to the user: "before I start, here's what I found."

Ground in the 2026-05-23 session: `ai/testing-guidelines.md` §6 documented a `phase × action` workflow_dispatch matrix. The actual `terraform-test.yml` exposed only `mode = plan-only | apply-and-destroy`. Had the agent run a preflight cross-check, this would have been the *first* thing said to the user — instead, it surfaced as a Phase-2 surprise that consumed a clarification round before the work could even start.

## Trigger

### Direct triggers

- Agent has just read a procedural doc and is about to execute its steps.
- User says "follow procedure P" / "do the runbook" / "work on phase N" / similar where P/runbook/phase is described in a doc.
- Agent reads `CLAUDE.md` or `AGENTS.md` and sees it delegates to a doc with executable steps.

### Proactive triggers

- Any session opening where the first user message names a documented procedure.
- After spawning a subagent whose brief references a runbook the subagent itself didn't author.

### Negative triggers (skip)

- The procedural doc is purely conceptual (a design rationale, an ADR explaining a past decision without prescribing future steps).
- The procedure is one-shot and the agent has already executed it in this session.
- The doc was written by the agent in the current session (the agent already knows it matches reality).

## Inputs

- The procedural doc(s) the agent has read (paths, contents).
- The repo working tree (read-only access via `Read`, `Grep`, `Bash` with `ls`/`cat`/`grep`).
- Optionally: the tool capability list (which MCP tools are loaded, which CLIs are on PATH).

## Outputs

- A short on-screen manifest before the agent starts the task, of the form:

  ```
  Preflight check — doctrine vs implementation:

  ✓ <doc §A> references workflow `<path>` — exists, exposes the documented inputs
  ✓ <doc §B> references script `<path>` — exists and is executable
  ✗ <doc §C> claims `<artifact>` — NOT FOUND
    → consequence: <which procedure step is now blocked>
    → options: (a) build the missing artifact first; (b) ...
  ⚠ <doc §D> assumes capability `<tool/cli>` — not available in this environment
    → consequence: <which procedure step is blocked>
    → options: (a) escalate; (b) work around with <alt>
  ```

- No commit, no file write. Pure read-only orient-time output.
- The agent then awaits user direction OR proceeds (per the source procedure's "don't ask for clarification" clause, if such a clause exists *and* there are no `✗`/`⚠` rows).

## Workflow

1. **Identify the procedural doc(s).** From the user's message and from `CLAUDE.md`/`AGENTS.md`, list the docs that prescribe the requested procedure. Typical paths: `ai/testing-guidelines.md`, `docs/runbook.md`, `RUNBOOK.md`, anything matching `*-procedure.md` or `*-guidelines.md`.

2. **Extract concrete artifact references.** Scan each doc for the following patterns and produce a list:
   - File paths (anything matching `[a-z./_-]+\.(yml|yaml|sh|py|tf|json|md)`).
   - Workflow_dispatch input names (look for tables of `phase × action` shape, or `inputs:` mentions).
   - Environment variable names (`TF_VAR_*`, `AWS_*`, etc.).
   - CLI command names (`gh`, `aws`, `kubectl`, `terraform`, etc.).
   - Script names (`compute-gates.sh`, etc.).

3. **Spot-check each reference against the live repo / environment.**
   - File paths: `test -e <path>` (or `ls`); for YAML, additionally grep for the documented inputs/keys.
   - Workflow_dispatch inputs: read the workflow YAML and confirm the documented inputs exist with the documented choices.
   - Env vars: grep `.github/workflows/`, `Dockerfile`, `.envrc`, `terraform/*/variables.tf` for either definition or use.
   - CLIs: `command -v <cli>` from within the agent's shell; if unavailable, check whether an MCP equivalent exists.
   - Scripts: `test -x <path>`.

4. **Classify each check.** `✓` = matches doctrine. `✗` = artifact missing entirely. `⚠` = artifact exists but its shape diverges from the doc (e.g., workflow exposes `mode` instead of `phase`+`action`). Both `✗` and `⚠` need surfacing.

5. **Emit the manifest before any other action.** The manifest is the first user-facing output. If the manifest is all `✓`, the agent proceeds with the procedure (subject to the doc's "don't ask" clause). If anything is `✗` or `⚠`, present the manifest, list consequences, and either (a) propose the gap-closing work as the next step or (b) ask the user only when ambiguity remains.

6. **For tool/CLI gaps specifically: escalate as a tooling issue, not a design problem.** If the gap is "agent lacks tool X needed by the procedure," frame the user-facing message as "I lack capability X — should I escalate this as a platform-tooling gap, work around it, or wait?" Do **not** silently proceed to design a workaround.

## Concrete examples

### Example 1 — the 2026-05-23 session, retrofitted

User says: "Start testing phase 1."

The skill activates because `CLAUDE.md` delegates "work on phase N" to `ai/testing-guidelines.md` §3. The agent reads §3 and §6 and produces:

```
Preflight check — ai/testing-guidelines.md vs implementation:

✓ §3 references `ai/handoff.md` Current Sandbox Session block — exists
✓ §3 references `.claude/skills/terraform-ci-watch/` — exists
✗ §6 documents workflow_dispatch inputs (phase, action) on
  `.github/workflows/terraform-test.yml`
  → actual: only `mode = plan-only | apply-and-destroy` is exposed
  → consequence: every action verb §3 prescribes (apply-and-verify, verify, destroy)
                 has no dispatch path in the current YAML
  → options: (a) refactor the workflow to match §6 before starting phase 1
             (b) bring up phase 1 via the existing apply-and-destroy mode,
                 accepting that it will destroy at the end (violates CLAUDE.md
                 invariant 2)
⚠ §3 step "dispatch workflow_dispatch (phase=K, action=apply-and-verify)"
  → agent lacks workflow_dispatch tool in this environment
  → consequence: I can refactor the YAML, but I can't fire CI myself
  → options: (a) escalate as platform-tooling gap; (b) human dispatches each fire
```

The user can now decide between "refactor first" and "escalate the tooling gap" with full context, in the *first* round of conversation. Counterfactual (what actually happened): the manifest's first two rows surfaced only after the agent had already started reading the workflow file; the third row surfaced after PR #17 was already merged.

### Example 2 — a hypothetical deployment runbook

User says: "Deploy to staging."

The skill reads `docs/deployment-runbook.md` and produces:

```
Preflight check — docs/deployment-runbook.md vs implementation:

✓ step 1 references `scripts/build.sh` — exists, executable
✓ step 2 references env var `STAGING_DEPLOY_TOKEN` — referenced in `.github/workflows/deploy.yml`
✗ step 3 references `helm/staging/values.yaml`
  → actual: file does not exist; `helm/staging/` directory is empty
  → consequence: `helm upgrade` in step 3 has no values file to pass
  → options: (a) ask which values file should be used
             (b) ask user to provide the staging values
⚠ step 4 says "use the `dep` CLI to..."
  → agent lacks `dep` CLI in this environment
  → consequence: cannot execute step 4
  → options: (a) escalate; (b) ask user to run step 4 and report back
```

## Anti-patterns

- **Doing the preflight check silently and proceeding.** The point of the manifest is the visibility, not the check. Even an all-`✓` manifest should be emitted (briefly — one line per `✓` is fine) so the user knows the cross-check happened.
- **Treating a `✗` as "I should build it myself, immediately, without asking."** A missing artifact is a fork in the road: the user might want it built, might want the doc updated to match reality, or might know the artifact lives in a separate repo. Surface the gap, then act.
- **Skipping the check because the doc "feels familiar."** The 2026-05-18 retro authored testing-guidelines.md §6; the 2026-05-23 session was a different agent run that had not internalized that the YAML didn't actually expose those inputs yet. "Familiar" is not "verified."
- **Listing every file mentioned in the doc, including illustrative ones.** Only check artifacts whose existence the *procedure* depends on. A doc that mentions `clusters/my-cluster/` as an example layout shouldn't trigger a check for `clusters/my-cluster/` existing.
- **Running the check at end-of-task instead of start-of-task.** A preflight at the end is a post-mortem; the value is in the pre-, not the -flight.

## Acceptance criteria

1. Skill runs in under 120 seconds of agent time on a repo with ≤10 docs and ≤20 referenced artifacts.
2. Produces a manifest with at least one row per concrete artifact referenced by the procedural doc.
3. Distinguishes `✓` / `✗` / `⚠` correctly (matches / missing / shape-divergent).
4. For every `⚠`, names the specific divergence (not just "doesn't match").
5. For every `✗` and `⚠`, lists at least two next-step options.
6. Does NOT write any file or make any commit.
7. The manifest is the first user-facing output of the task, before any other action.

## Files this skill creates / modifies

- `.claude/skills/doctrine-impl-preflight/SKILL.md` — the skill body following the standard skill format.
- (Optional) `.claude/skills/doctrine-impl-preflight/reference/artifact-patterns.md` — the regex patterns the skill uses to extract artifact references from prose docs. Worth splitting out if the pattern list grows past 8–10 entries.

No project-side files are created or modified. The skill is read-only and produces chat-only output.
