# Comments that couldn't be attached to a specific source idea (general_comments).
# These are the rows where regex extraction found no A{N}-NNN reference matching the target agent.
# Usage: jq -f ai/brainstorming/tools/queries/orphan-comments.jq ai/brainstorming/brainstorm.json
[
  .agents[]
  | { agent: .id, count: (.general_comments | length), samples: (.general_comments | .[0:3] | map({comment_id, from_agent, idea})) }
]
