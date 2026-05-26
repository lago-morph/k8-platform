# agent instruction

**Use mikefarah yq v4 syntax (not jq syntax) in tests under `tests/unit/`.** "CI installs mikefarah yq v4 (currently v4.44.3 per the `unit-tests.yml` step). Do NOT use jq-style fallbacks like `// empty`; use `select(.field != null)` filters or empty-string fallbacks `// \"\"`. Locally a different yq variant may forgive the syntax; CI will not. Verify any new yq assertion locally with the same binary CI installs."

*Grounded in: 2026-05-26 v1→v2 migration, PR #104 unit-tests failure on `composition_providerConfigRef_kinds_present`.*

# justification

PR #104 went red on a yq syntax error (`Error: 1:73: invalid input text "empty"`) that the SEG-3 subagent's local test pass didn't catch. The sandbox-installed yq apparently tolerates `// empty`; mikefarah v4 in CI does not. Cost of adopting: one-line awareness check in any PR adding yq queries (and ideally, mention mikefarah's syntax quirks in the test-authoring documentation). Cost of NOT adopting: a CI red-then-fix cycle per offending query, plus the loss of trust when CI fails on "obviously correct" expressions.
