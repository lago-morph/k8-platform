# Archived skills

Skills moved out of the active set (`.claude/skills/`) during the 2026-06-10
instruction-surface restructure (forensics round 2). The harness does not load
skills from this directory, so their descriptions no longer cost tokens every
session. Restoring one is a single `git mv` back into `.claude/skills/`.

**Why archived** (admission rule: `ai/LESSONS.md` §3.2 — a skill earns its
per-session load only as an environment bridge, a repeatedly-used domain loop,
or an owner-valued interface):

| Skill | Reason |
|---|---|
| `autonomous-run` | Unattended volume runs are **paused** by owner direction until the clean-build gate is green twice (LESSONS S5); the protocol's volume incentives are themselves implicated (forensics D7) |
| `parallel-subagent-fanout` | Companion protocol to `autonomous-run`; archived with it |
| `subagent-prompting`, `model-aware-dispatch`, `post-edit-reread-pass`, `protocol-reachability-spike`, `adversarial-plan-synthesis` | Generic methods; their load-bearing intent is distilled into AGENTS.md (subagents/planning section). Restore if the one-line forms prove insufficient |
| `in-flight-workflow-tracking` | Covered by the CI-mechanics facts in `ai/environment.md` §6 |
| `retro-coverage-audit-and-backfill` | Remedy-channel volume machine (D8-adjacent); the forensic record forbids synthetic back-fill into evidence (LESSONS L28) |
| `stacked-pr-on-feature-branch` | The standing owner override + base-selection rule are one paragraph, now in AGENTS.md / environment.md |
