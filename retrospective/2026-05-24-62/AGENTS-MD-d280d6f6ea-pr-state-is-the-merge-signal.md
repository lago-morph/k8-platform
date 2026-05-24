# agent instruction

**§3.X — PR draft/ready state is load-bearing UI.** When the agent opens a PR, the `draft` flag MUST reflect the agent's actual signal to the user:
- `draft: true` when CI is red/yellow, when the agent is still iterating, or when there's an explicit hold instruction
- `draft: false` (ready for review) when CI is green AND the agent wants the user to merge

When CI greens on a draft PR with intent-to-merge, the agent MUST promote it via `update_pull_request method=update draft: false` and tell the user. When listing open PRs in status updates, the agent MUST name each PR's draft/ready state explicitly.

*Grounded in: this session opened 10 PRs as draft regardless of state; the user explicitly corrected this mid-session ("leave PRs you are still working on in draft, and ones you want me to merge as ready"). The very next PR (#61) was opened ready, CI green, and merged smoothly.*

# justification

The user has limited bandwidth to triage PRs. If every PR is draft, they have to ask the agent each time which to merge. That's friction proportional to PR count — and this session shipped 11. The fix is zero-cost on the agent's side (set one flag correctly) and removes the user-side ambiguity entirely.

---
