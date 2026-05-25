# Top ideas by comment count — surfaces what the cross-review pass converged on.
# Usage: jq -f ai/brainstorming/tools/queries/most-discussed.jq ai/brainstorming/brainstorm.json | head -40
[
  .agents[].ideas[]
  | { id, idea, category, comment_count: (.comments | length), commenters: ([.comments[].from_agent] | unique) }
]
| sort_by(-.comment_count)
| .[0:25]
