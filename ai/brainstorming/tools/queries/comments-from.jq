# All comments authored by a specific reviewer (A1..A6 or PRIMARY), de-duplicated by comment_id.
# Usage: jq -f ai/brainstorming/tools/queries/comments-from.jq --arg from A3 ai/brainstorming/brainstorm.json
[
  ([.agents[].ideas[].comments[]] + [.agents[].general_comments[]])
  | .[]
  | select(.from_agent == $from)
]
| unique_by(.comment_id)
