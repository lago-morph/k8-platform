# AGENTS.md suggestions — 2026-05-23-32

These are proposed additions to the project's agents file (typically `CLAUDE.md` at the repo root for this project, or `AGENTS.md` for generic projects). Each section contains:

1. **Proposed addition** — the exact text to paste.
2. **Why this earns its place in your agents file** — the argument for doing it, grounded in something that happened (or nearly happened).

Decide each on its own merits. Skip ones that don't apply to your operating posture; copy-paste the ones that do.

---

## Suggestion 1: The "portability question" before committing

### Proposed addition

> **Ask the portability question before committing skill or doc changes that name a specific tool, CLI, MCP server, or sandbox feature as load-bearing.** Before opening (or expanding) a PR whose instructions tell the agent to use `gh`, `aws`, a specific MCP tool name, a sandbox-specific path, or any other environment-dependent capability, ask: "is this universally true, or specific to the current environment?" If specific, structure the doc to support detection + dispatch rather than hardcoding the current environment's path. The pattern lives in the `portable-skill-design` skill and the worked example at `.claude/skills/terraform-ci-watch/reference/capabilities.md`.
>
> *Grounded in: PR #32 commit 1 (`89a9884`) hardcoded `ext-github` as the sole path; commit 2 (`acbe1eb`) generalized after user catch.*

### Why this earns its place in your agents file

The session shipped commit 1 in confidence — the system reminder "you do NOT have access to the gh tool" arrived mid-work and I read it as confirmation that the design was right rather than as a hint that other environments might exist. The user caught the gap in PR review with a single message and the rework took ~25 minutes (one new file, five edited files, one cross-file grep). The cost of *not* having this rule: the user has to catch every instance of "the agent wrote for its own environment and called it universal" in review. The cost of having it: one sentence the agent reads at the start of any skill/doc PR, and a 30-second mental check before commit. The asymmetry is extreme. The rule also names the worked example, so an agent that doesn't yet understand the pattern has a concrete file to copy from.

---

## Suggestion 2: Don't conflate "new capability landed" with "new capability is THE path"

### Proposed addition

> **Distinguish "this capability exists" from "this capability is the only path."** When updating instructions to reflect a new tool or skill, separate the two claims explicitly. "We now have `ext-github`" is true; "`ext-github` is the only way to reach the Actions API" is true only in the current sandbox. The first claim is universal; the second is environment-specific. If you can't tell from context which one applies to a given doc edit, ask before committing. Prefer phrasing like "the agent uses whichever capability profile is available" over "the agent uses X" unless X is genuinely universal.
>
> *Grounded in: PR #32 commit 1 replaced "the agent invokes terraform-test.yml directly via the GitHub API" with "the agent invokes it from the sandbox via ext-github" — narrower than the original. The original was actually more correct, just less specific.*

### Why this earns its place in your agents file

This is the *mechanism* behind suggestion 1. Suggestion 1 says "ask the portability question"; this one says what the question actually is. The session demonstrated that the trap is easy to fall into precisely because the narrowing feels like a precision upgrade ("we now know the specific path, let's name it"). The framing matters: "the agent uses whichever capability profile is available" is the same length as "the agent uses ext-github" but communicates the right invariant. The cost is a habit shift — phrase universally first, narrow only with evidence — and it can be applied during normal writing, not as a separate review pass.

---

## Suggestion 3: Cross-file `grep` after coordinated multi-file edits

### Proposed addition

> **After a coordinated edit touching more than three files — especially when introducing or renaming an abstraction shared across them — run a cross-file `grep` for the key tokens (operation names, abstraction names, cross-references to anchors like §1/§2/§3) before committing.** The goal is to catch drift: an operation renamed in file A but not file B, a cross-reference to `§3` when the target moved to `§4`, an anchor name typo'd in one of N callsites. One `grep` invocation is enough; the cost is seconds, and the most common consequence of skipping it (a broken cross-reference in a load-bearing doc) is invisible until a future agent follows the wrong pointer.
>
> *Grounded in: the rework in PR #32 commit 2 introduced 5 abstract operation names (LOCATE_RUN, POLL_RUN, LIST_FAILED_JOBS, FETCH_JOB_LOG, DISPATCH) across 6 files, plus 3 profile names (`gh`, `github-mcp`, `ext-github`), plus 8 anchor references to `capabilities.md` sections. A single `grep` confirmed all consistent before commit.*

### Why this earns its place in your agents file

For multi-file coordinated edits, the dominant failure mode is internal inconsistency, not individual file bugs. A spelling drift in one of seven occurrences will compile cleanly, type-check cleanly, and pass every per-file review — and then fail silently when a future agent follows the renamed-but-not-everywhere abstraction. The session ran the cross-file grep proactively and caught nothing (the rework had no drift), but the cost was a single tool call and the upside is "definitely no drift" vs "probably no drift." This rule lives well next to the `post-edit-reread-pass` skill that already exists for the same class of risk.

---

## Suggestion 4: Mid-loop capability re-detection is a feature, not an escalation

### Proposed addition

> **Skills that drive operations against external services should treat connectivity failures as triggers to re-detect capabilities, not as triggers to escalate immediately.** If a transport fails for a connectivity reason (CLI gone missing, MCP tool returns "unavailable", broker 5xx), re-run the skill's detection sequence once. If detection picks a different transport, retry the operation under it. Escalate only if detection produces "none" or the same failing transport. This pattern is documented in `.claude/skills/terraform-ci-watch/reference/capabilities.md` §3 as "mid-loop degradation." Apply it to any new skill that has multiple transport candidates.
>
> *Grounded in: `capabilities.md` §3 introduced in PR #32 as a structural rule, not a per-skill ad-hoc behavior.*

### Why this earns its place in your agents file

Connectivity failures are inherently transient, but they look exactly like permanent failures from inside the skill (a 5xx is a 5xx). The default behavior — escalate to the user — is correct only when no fallback exists; when a fallback DOES exist, escalating without re-detecting wastes the user's attention. The session's rework codified this as a §3 rule because the alternative was leaving each profile responsible for its own degradation logic, which would have produced three inconsistent escalation behaviors. The rule generalizes: any skill that has more than one transport candidate should think about mid-loop degradation up front, because retrofitting it later means changing the skill's contract with its caller.

---

## Note on the agents-file filename

This project uses `CLAUDE.md` (not `AGENTS.md`). The rules above can be pasted into `CLAUDE.md` directly — adapt section headers as needed. If the project later adopts a generic `AGENTS.md` convention, the same text moves over unchanged.
