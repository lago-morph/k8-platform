# Idea count per agent (compact summary).
# Usage: jq -f ai/brainstorming/tools/queries/ideas-by-agent.jq ai/brainstorming/brainstorm.json
[
  .agents[]
  | { agent: .id, short: .short_mandate, ideas: (.ideas | length), comments: ([.ideas[].comments[]] | length), general: (.general_comments | length) }
]
