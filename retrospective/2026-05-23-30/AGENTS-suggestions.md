# AGENTS.md suggestions — 2026-05-23-30

These are proposed additions to the project's agents file (`CLAUDE.md` at the repo root for this project). Each section contains:

1. **Proposed addition** — the exact text to paste.
2. **Why this earns its place in your agents file** — the argument for doing it, grounded in something that happened (or nearly happened) this session.

Decide each on its own merits. Skip ones that don't apply.

---

## Suggestion 1: Fine-grained PATs targeting an org repo must use the org as resource owner

### Proposed addition

> **Fine-grained PAT resource-owner gotcha.** A fine-grained PAT generated against your **personal** GitHub account cannot see repositories owned by an organization, regardless of the repository selection inside the token UI. When the upstream is an org-owned repo (e.g. `lago-morph/k8-platform`), the resource owner field on the token must be set to the org, AND the org must have "Allow access via fine-grained personal access tokens" enabled in its Personal Access Tokens policy. If you see an unexplained `401 Bad credentials` from a token that "looks right," check the resource-owner setting first.
>
> *Grounded in: 2026-05-23 PR2 live-fire opened with a 401 from a personal-scope PAT.*

### Why this earns its place in your agents file

The first attempt to live-fire PR2's `workflow_dispatch` returned 401 with no diagnostic detail. The PAT had been generated against the user's personal account and the repository-selection UI did not warn that lago-morph's repos were unreachable from this scope. Diagnosing it took a round-trip ("can I generate one in the org?") and a token regeneration — call it 10 minutes plus user attention. Multiply that by every future agent that hits this for the first time, against any org-owned upstream that gets bridged through jentic.

The marginal cost of the rule is zero — it's a single bullet under the existing **Required GitHub Actions Secrets** section, and it pays off the first time anyone provisions a new ext-bridge for an org-owned upstream. The pattern is also generic: it applies to any future `ext-*` skill that wraps an org-owned API surface.

---

## Suggestion 2: Every `ext-*` recording must carry `last_verified` and SKILL.md must surface it

### Proposed addition

> **`ext-*` recordings carry a verification date.** Every `resources/*.json` in an `ext-{service}` child skill MUST include `"last_verified": "YYYY-MM-DD"`. The child's `SKILL.md` endpoint table MUST surface that date in a `Last verified` column. On any re-verify event (live-fire re-run that confirms the recording still works), bump BOTH the JSON `last_verified` AND the SKILL.md table cell in the same commit. The date is the only freshness signal the skill ships — there is no periodic CI smoke test by design.
>
> *Grounded in: 2026-05-23 PR #30 added the convention after the user requested verification dates "for debugging later."*

### Why this earns its place in your agents file

This came directly from a user instruction during PR2 authoring: *"You should also put dates next to when you last verified the workflow. Might be useful for debugging later."* The point holds for every future `ext-*` skill: when an endpoint starts failing months from now, the first question a debugger asks is "when did this last work?" Without `last_verified`, the answer is buried in git history at best, and lost at worst. With it, the answer is one column away in the SKILL.md table.

The marginal cost is one line per recording and one row per endpoint table — already enforced procedurally by the pre-commit checklist, but currently soft. Promoting it to a project rule means a future validator (see the `ext-skill-validate` skill spec in this retro) has a definite contract to check against.

---

## Suggestion 3: Catalog/bridge gaps belong in the skill, not in chat

### Proposed addition

> **Document live-fire workarounds inside the skill.** When a live-fire probe reveals that a needed endpoint is absent from jentic's catalog OR returns errors through the bridge that don't appear when calling the upstream directly, the resulting `ext-{service}/SKILL.md` MUST include a "Catalog gaps & workarounds" section that names each broken endpoint, documents the substitute call sequence, and gives a re-check condition (what would make the gap go away). Do NOT silently omit the broken endpoint — a future agent will rediscover the same gap and waste the same time.
>
> *Grounded in: 2026-05-23 PR #30 documented two such gaps (missing `actions/get-workflow-run`; broken `actions/download-workflow-run-logs`).*

### Why this earns its place in your agents file

Two of PR2's six probed endpoints failed in ways that aren't documented anywhere upstream — jentic's catalog doesn't advertise its own gaps, and GitHub's API docs obviously don't comment on jentic's redirect-following ability. The cost of NOT capturing them in the skill: every future session that needs (say) run-wide logs will re-discover the 500, re-investigate, re-design a substitute, re-test it. The cost of capturing them: one paragraph per gap inside SKILL.md (the §3 we added in PR #30).

The user named this explicitly: *"make sure that these workarounds make their way into the new skill."* That instruction generalizes to every future ext-bridge — once the rule is in the agents file, it covers `ext-aws`, `ext-stripe`, anything else.

---

## Suggestion 4: Skill discoverability via aggressive `description:` is load-bearing

### Proposed addition

> **Aggressive skill descriptions are the discoverability mechanism.** `ext-*` skills (and other skills that wrap a narrow set of operations) MUST carry a `description:` frontmatter field that names every endpoint they cover, every trigger phrase a future agent would search for (verbs like "dispatch", "trigger", "list runs", "fetch logs"), and the specific gap (egress blocked / no MCP coverage / MCP advertised-but-broken). There is intentionally no `CLAUDE.md` index of skills, no SessionStart hook scan, and no `INDEX.md`. If the description is generic, the skill is functionally invisible.
>
> *Grounded in: 2026-05-23 — within seconds of `.claude/skills/ext-github/SKILL.md` being written, the harness's available-skills list surfaced "ext-github" with the full trigger phrase set. The mechanism worked as designed.*

### Why this earns its place in your agents file

The session contained a real-time confirmation of the spec's Resolution #5: the harness's skill-discovery scan picks up `description:` text and surfaces the skill in the available-skills list immediately. No index plumbing needed. But that discovery mechanism only works to the extent the description is generous — a one-line "wraps GitHub API" description would have been invisible to a future agent searching for "trigger CI" or "list workflow runs."

This is the kind of rule that's easy to forget mid-authoring (when the agent is focused on the §1–§7 body) and hard to retrofit later (because by then no one is searching for the skill, because it's invisible). Putting it in the agents file makes "be aggressive in `description:`" a checked-in habit, not an authoring-time afterthought.
