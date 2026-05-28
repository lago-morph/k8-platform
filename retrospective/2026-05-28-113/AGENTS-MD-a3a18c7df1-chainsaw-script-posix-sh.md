# agent instruction

**Chainsaw `script.content:` blocks run under `/bin/sh`, NOT bash.** "On Ubuntu (the chainsaw GitHub Actions runner default), `/bin/sh` is `dash`, which rejects bash-only constructs: `set -o pipefail`, `set -euo pipefail`, `[[ ... ]]`, `<<<` here-strings, `(( ... ))`, process substitution `<(...)`, arrays, and brace expansion. Use POSIX-portable constructs in every `script.content:` block: `set -eu` instead of `set -euo pipefail`; `[ ... ]` (single-bracket) instead of `[[ ... ]]`; pipes via temporary files if you'd otherwise want pipefail. The wrapper `tests/chainsaw/run.sh` is bash (it has a bash shebang) and can use full bash; but anything inside `script.content:` is sh."

*Grounded in: auto-003 chainsaw run 26545542710, where `set -euo pipefail` in 4 script blocks exited 2 with `sh: 1: set: Illegal option -o pipefail` after the conditions-array fix from Strike 2 unblocked chainsaw past the assert step.*

# justification

The 245s timeout symptom hid this bug behind every prior chainsaw failure for the platform-secret scenarios. Once the earlier failure modes were fixed (em-dash + conditions), this latent bug surfaced and chainsaw failed in ~3 minutes instead of ~15 because the script step errored immediately. A 30-line `tests/unit/test_chainsaw_script_shell_portable.sh` enforcer (added in PR #105 commit `9103d9a`) prevents regression. Cost of adopting: scenario authors write portable shell; the enforcer scans for `set -*o*pipefail` (the primary marker) and fails CI. Cost of NOT adopting: a CI red-then-fix cycle per bash-ism, with the failure mode "scripts error at step 1" that the catch block ALSO doesn't usefully diagnose (because the catch block is for k8s state, not script exit codes).
