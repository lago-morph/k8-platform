# jq queries for `brainstorm.json`

All queries assume the working dir is the repo root and `jq` is installed.

| Query | Purpose | Example |
|---|---|---|
| `totals.jq` | Top-level idea/comment counts | `jq -f ai/brainstorming/tools/queries/totals.jq ai/brainstorming/brainstorm.json` |
| `ideas-by-agent.jq` | Per-agent counts of ideas + comments | `jq -f .../ideas-by-agent.jq ai/brainstorming/brainstorm.json` |
| `idea-by-id.jq` | Look up one idea + all its comments | `jq -f .../idea-by-id.jq --arg id A1-019 ai/brainstorming/brainstorm.json` |
| `most-discussed.jq` | Top 25 ideas by comment count | `jq -f .../most-discussed.jq ai/brainstorming/brainstorm.json` |
| `by-phase.jq` | Ideas applicable at a given phase or earlier | `jq -f .../by-phase.jq --arg phase 2 ai/brainstorming/brainstorm.json` |
| `by-category.jq` | Filter ideas by category substring | `jq -f .../by-category.jq --arg cat runbook ai/brainstorming/brainstorm.json` |
| `comments-from.jq` | All comments from one reviewer | `jq -f .../comments-from.jq --arg from A3 ai/brainstorming/brainstorm.json` |
| `orphan-comments.jq` | Comments with no resolvable source-ID reference | `jq -f .../orphan-comments.jq ai/brainstorming/brainstorm.json` |

## Rebuild + verify cycle

```
python3 ai/brainstorming/tools/build_brainstorm_json.py
python3 ai/brainstorming/tools/verify_brainstorm.py
python3 ai/brainstorming/tools/lint_brainstorm.py
```

The build step is idempotent; running it again only rewrites `brainstorm.json`
if the markdown inputs changed.
