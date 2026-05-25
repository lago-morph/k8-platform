# agent instruction

**Validate Mermaid syntax before committing.** Before committing a Mermaid diagram to the repository, validate it via the `mcp__*__validate_and_render_mermaid_diagram` tool (or the equivalent local CLI). A diagram that fails to render is a documentation bug the reader will never see it work. Save the rendered PNG if the diagram is non-trivial; attach it to the PR for review-time clarity.

*Grounded in: 2026-05-25 session where a broken Gantt mermaid in IMPLEMENTATION-PLAN.md shipped via PR #80 and was only caught when the user shared a screenshot.*

# justification

PR #80 shipped a Gantt diagram in `IMPLEMENTATION-PLAN.md` that rendered as a confusing mess: implement bars were 2 cycles, soak bars only 1, the `after-p1` chain syntax obscured the actual overlap, and `axisFormat %s` produced "0 0 0 1 1 1" axis labels. The agent never validated the diagram before committing — and the bug wasn't caught until the user screenshotted the broken render and asked "can you fix the mermaid diagram? I don't understand what's going on." A second PR (#81) was needed to fix it.

The cost of validating: one tool call (~3 seconds) plus an optional PNG attached to the PR. The cost of NOT validating: a full PR round-trip to fix a documentation bug, plus the cognitive overhead of the user trying to parse a broken diagram. The validator tool exists, is cheap, and returns a usable PNG you can hand to the user as proof the diagram reads correctly. Validate every mermaid before commit.
