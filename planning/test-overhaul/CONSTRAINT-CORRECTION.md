# Constraint correction (2026-06-07) — workflow files CAN be edited here

**Supersedes a false premise used in the synthesized plan and the round-2 review briefs.**

Several artifacts in this directory state that this environment **cannot** edit
`.github/workflows/*` (citing OI-2026-06-05-6), and therefore conclude that
enforcement (the skip-count / coverage / executed-test-floor gate) **must** be routed
through the already-push-gated `tests/unit/run.sh` rather than a dedicated verifier
workflow.

**That constraint is WRONG.** The repository owner confirmed: workflow files **can**
be created/edited in this environment **via jentic's Contents-PUT** (the `ext-github`
skill, `create_or_update_file_contents` / `op_12ee1daaad73b14b`). The git-push OAuth
token and the GitHub MCP write tools lack `workflow` scope, but the jentic path does
not — so `.github/workflows/*` changes ARE landable.

## Implication for finalization

The enforcement-vehicle choice is a **genuine design decision on the merits**, NOT a
forced move:

- **`tests/unit/run.sh`-routed gate** — runs on every push (locally + in the
  unit-tests workflow) with no workflow-scope dependency; simplest; already gated.
- **A dedicated verifier workflow** (e.g. a `live-verify` / coverage-gate workflow,
  landed via jentic) — can gate the PR check directly, run on a schedule or
  workflow_dispatch, and carry richer logic; now fully available.
- **Likely best: BOTH** — keep an always-on `run.sh` lint/coverage gate as the
  push-time floor, AND a verifier workflow for the live/PR-gating layer.

The finalizer MUST: (a) remove the "can't edit workflows" claim wherever it appears,
(b) re-evaluate any finding/decision that was premised on it, and (c) state the
enforcement-vehicle choice as a deliberate decision (recommending the both-layers
approach unless there's a concrete reason not to). The jentic/`ext-github` path is the
mechanism for landing any `.github/workflows/*` changes the plan calls for.
