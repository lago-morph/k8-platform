# Ideas applicable to a given phase (or earlier).
# Usage: jq -f ai/brainstorming/tools/queries/by-phase.jq --arg phase 2 ai/brainstorming/brainstorm.json
[
  .agents[].ideas[]
  | select((.applies_to_phase | rtrimstr("+") | tonumber) <= ($phase | tonumber))
  | { id, agent: (.id | split("-")[0]), idea, category, applies_to_phase }
]
