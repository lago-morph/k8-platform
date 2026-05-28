# Spec: `chainsaw-script-shell-portability`

- **ID**: SKILL-SPEC-79be4c2c08
- **Source retrospective**: ../2026-05-28-113.md

## Intent

Audit every chainsaw `script.content:` block for bash-only constructs and convert them to POSIX-portable shell. Chainsaw runs scripts under `/bin/sh` (`dash` on Ubuntu), not bash. `set -o pipefail`, `[[ ... ]]`, `<<<`, `((...))`, process substitution, and arrays all fail with `Illegal option` or syntax errors. The skill rewrites them to portable equivalents.

## Trigger

Activate when:
- User adds a new chainsaw scenario with `script.content:` blocks.
- User extends an existing `script.content:` block with new commands.
- A chainsaw run fails with `sh: 1: set: Illegal option` or `sh: 1: ...: not found` for a bash builtin.
- User runs `bash tests/unit/test_chainsaw_script_shell_portable.sh`.

Do NOT activate for:
- `tests/chainsaw/run.sh` — that's the bash wrapper with `#!/usr/bin/env bash`. Bash syntax is fine there.
- Scripts inside `try.script.bash:` (chainsaw doesn't have this; the skill only applies to standard `script.content:`).

## Inputs

- Working tree of chainsaw scenarios.
- Optional: chainsaw failure log.

## Outputs

- For each `script.content:` block, the bash-isms are rewritten to portable equivalents:
  - `set -euo pipefail` → `set -eu` (drop pipefail; document via comment).
  - `[[ ... ]]` → `[ ... ]` (rewrite tests; quote variables).
  - `<<<` → temp file + redirect.
  - `((...))` → `expr ...` or `$((...))` (POSIX arithmetic).
- Summary report listing changes.

## Workflow

1. Discover candidate files: `find tests/chainsaw -name 'chainsaw-test.yaml' -type f`.
2. For each file, parse YAML and locate every `script.content:` block.
3. For each block content (a multi-line string):
   a. Scan for `set -.*o.*pipefail` → replace with `set -eu` (drop pipefail).
   b. Scan for `[[ ` → replace with `[ ` and `]]` with `]` (with quote-fix on variables).
   c. Scan for `<<<` → rewrite as `printf '%s' "$VALUE" | command` or temp file.
   d. Add an explanatory comment after the `set` line: `# chainsaw runs scripts under /bin/sh; pipefail is bash-only.`
4. Run `tests/unit/test_chainsaw_script_shell_portable.sh` to verify.
5. Print summary.

## Concrete examples

**Example 1 — original bash-only**:
```yaml
- script:
    content: |
      set -euo pipefail
      key="k8-platform/${UID}"
```
After skill:
```yaml
- script:
    content: |
      set -eu
      # chainsaw runs scripts under /bin/sh; pipefail is bash-only.
      key="k8-platform/${UID}"
```

**Example 2 — `[[ ]]` test**:
```yaml
- script:
    content: |
      set -euo pipefail
      if [[ -z "$VAR" ]]; then
        echo "empty"
      fi
```
After skill:
```yaml
- script:
    content: |
      set -eu
      # chainsaw runs scripts under /bin/sh; pipefail is bash-only.
      if [ -z "$VAR" ]; then
        echo "empty"
      fi
```

## Anti-patterns

- **Specifying `script.shell: bash` and hoping chainsaw honors it.** Chainsaw 0.2.x doesn't expose a shell selector for `script.content:`; the only path is portable shell.
- **Wrapping the script in `bash -c '...'`.** Works but is ugly and loses the `script.content:` literal-block UX.
- **Ignoring the `pipefail` warning because the script doesn't pipe anything.** dash exits 2 on `set -o pipefail` even without an active pipe. The first `set` invocation fails immediately.

## Acceptance criteria

1. After the skill runs, no `script.content:` block contains `set -*o*pipefail`, `[[ `, `<<<`, or `(( `.
2. `tests/unit/test_chainsaw_script_shell_portable.sh` passes (7/7 currently).
3. The semantic behavior of each script is unchanged.
4. Each modified block carries an explanatory comment so future authors know why bash-isms were avoided.

## Files this skill creates / modifies

- `tests/chainsaw/platform-secret/{00,01,02}/chainsaw-test.yaml` — script blocks rewritten.
- `tests/chainsaw/_meta/composition-drift/chainsaw-test.yaml` — if present.
- `tests/unit/test_chainsaw_script_shell_portable.sh` — the verifier (already exists, PR #105 commit `9103d9a`).
