# agent instruction

**§6.X — Chainsaw `script:` blocks run in POSIX sh (dash on Ubuntu 24.04).** Inside a chainsaw `script:` block, use only POSIX-compatible code: `set -eu` (NOT `set -euo pipefail`), `[ ... ]` (NOT `[[ ... ]]`), no bash arrays, no process substitution. For pipefail semantics, restructure to avoid pipes or move the logic into `tests/chainsaw/run.sh` which runs in bash.

*Grounded in: chainsaw run 26346566417 failed with `sh: 1: set: Illegal option -o pipefail` despite three earlier-in-session uses of the same pattern not having tripped (the failures upstream of the script step masked it).*

# justification

The cost of the rule is one mental check per chainsaw scenario authored. The cost of not having it is what we saw: pattern propagated across the codebase via copy-paste and surfaced only when an upstream change exposed the script: step. Future agents authoring chainsaw scenarios are statistically likely to default to `set -euo pipefail` (the bash convention this codebase uses elsewhere); the rule prevents the propagation.

---
