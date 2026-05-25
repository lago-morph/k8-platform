# Look up a single idea by ID, with all its comments.
# Usage: jq -f ai/brainstorming/tools/queries/idea-by-id.jq --arg id A1-001 ai/brainstorming/brainstorm.json
.agents[].ideas[] | select(.id == $id)
