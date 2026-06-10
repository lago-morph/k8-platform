# 2. Authoritative specs

When work is scoped to one of the design specs in `ai/specs/`, that spec is
**the sole authoritative source** for the design. Do not derive design from
historical files (`retrospective/`, `summary/`, `ai/archive/`), from prior
commits, or from patterns found elsewhere in the repo. Conflicts resolve in
favor of the spec. If anything is ambiguous, ask — do not synthesize.

This rule exists because a prior session, while building the ext-github
skill, attempted to harmonize the spec with the (now deleted) trigger-file
machinery in the repo and produced a hybrid the user explicitly did not
want. Treat each spec as load-bearing.

---

*Source detail for `AGENTS.md`. The summary in AGENTS.md is authoritative for scope; this file holds the full text.*
