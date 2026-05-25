# Ideas matching a category (substring match).
# Usage: jq -f ai/brainstorming/tools/queries/by-category.jq --arg cat runbook ai/brainstorming/brainstorm.json
[
  .agents[].ideas[]
  | select(.category | test($cat; "i"))
  | { id, idea, category, applies_to_phase }
]
