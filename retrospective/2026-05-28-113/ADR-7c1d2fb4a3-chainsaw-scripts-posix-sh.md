# ADR: Chainsaw `script.content:` blocks are POSIX `/bin/sh`, not bash

- **ID**: ADR-7c1d2fb4a3
- **Status**: Draft (not yet adopted to docs/decisions/)
- **Date**: 2026-05-28
- **Source retrospective**: ../2026-05-28-113.md
- **PRs covered**: #105 (merged), #111 (open)

## Context

Chainsaw runs `script.content:` blocks via `sh -c` on the GitHub Actions runner. On Ubuntu (the default runner image), `/bin/sh` is `dash`, not `bash`. Bash-only constructs — `set -o pipefail`, `[[ ... ]]`, `<<<` here-strings, `((...))`, process substitution `<(...)`, arrays, brace expansion — all fail with `Illegal option` or syntax errors when executed under dash.

The auto-003 chainsaw run [26545542710](https://github.com/lago-morph/k8-platform/actions/runs/26545542710) surfaced this concretely: all 3 platform-secret scenarios errored at the first script step with:

```
sh: 1: set: Illegal option -o pipefail
exit status 2
```

The bash-ism had been latent for as long as the scripts had existed. Prior chainsaw runs never reached the script step because earlier failure modes (em-dash in AWS tags; missing Responsive condition in chainsaw asserts) bailed out before chainsaw could execute the script blocks.

## Decision

**All chainsaw `script.content:` blocks MUST be POSIX-portable.** Use `set -eu` instead of `set -euo pipefail`; `[ ... ]` instead of `[[ ... ]]`; explicit temp files instead of `<<<`. The wrapper `tests/chainsaw/run.sh` is bash (it has a bash shebang) and can use bash freely, but the chainsaw scenario files themselves are sh.

A unit test `tests/unit/test_chainsaw_script_shell_portable.sh` enforces this on every push by scanning for the primary marker `set -*o*pipefail` in any `chainsaw-test.yaml` (added in PR #105 commit `9103d9a`).

## Alternatives considered

- **Specify `script.shell: bash` in the YAML.** Chainsaw 0.2.x does not expose a shell selector at the `script:` step level. Rejected as not available in the pinned chainsaw version.
- **Wrap the script in `bash -c '...'`.** Works, but produces awkward escaping and loses the `script.content: |` literal-block UX. Rejected on readability grounds.
- **Switch the GitHub Actions runner to one where `/bin/sh` is bash.** Possible but introduces a non-default runner config that no other CI step in the repo needs. Rejected on minimum-surprise grounds.
- **Accept the bash-isms and let chainsaw fail on dash systems.** Rejected — the project's primary CI is GitHub Actions Ubuntu, and dash IS the default there. The bash-ism IS a bug.

## Consequences

**Easier:**
- Chainsaw scripts run reliably under any POSIX sh, not just on the bash subset the runner happens to ship.
- New contributors get an explicit constraint that's documented (the rule in `AGENTS.md` plus the unit test) rather than discovering it via a 3-minute CI failure.

**Harder:**
- Authors lose `pipefail`, which is a useful safety net for pipelines. The mitigation: explicit `|| true` or `command | tee /tmp/out; ec=${PIPESTATUS[0]}` patterns (the latter is actually a bash-ism — POSIX equivalents are uglier). For the platform-secret scenarios none of the existing pipes were load-bearing for error propagation, so dropping pipefail was safe; future authors must be more deliberate.

**Trade-off accepted:** lose pipefail and other bash conveniences in chainsaw script blocks, gain reliability and explicit-contract clarity. The chainsaw wrapper retains bash where bash is needed.

## References

- [`../2026-05-28-113.md`](../2026-05-28-113.md) — the source retrospective.
- [`./SKILL-SPEC-79be4c2c08-chainsaw-script-shell-portability.md`](./SKILL-SPEC-79be4c2c08-chainsaw-script-shell-portability.md) — the skill that implements this decision.
- [`./AGENTS-MD-a3a18c7df1-chainsaw-script-posix-sh.md`](./AGENTS-MD-a3a18c7df1-chainsaw-script-posix-sh.md) — the agents-file rule that codifies it.
- PR #105 merge `41e661d` — included commit `9103d9a` with the fix + TDD test.
- chainsaw run 26545542710 — the failing run.
- chainsaw run 26545816270 — the green run after the fix.
