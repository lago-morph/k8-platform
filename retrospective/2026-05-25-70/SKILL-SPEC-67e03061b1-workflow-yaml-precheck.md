# Spec: `workflow-yaml-precheck`

- **ID**: SKILL-SPEC-67e03061b1
- **Source retrospective**: ../2026-05-25-70.md

## Intent

Validate `.github/workflows/*.yml` before pushing whenever the change touches a `run: |` block, a heredoc, or embedded scripting. GitHub Actions silently refuses to register workflows that don't parse as YAML, and the `workflow_dispatch` API returns the misleading error `"Workflow does not have 'workflow_dispatch' trigger"` for unrelated reasons. The skill installs a one-line precheck (`python -c "import yaml; yaml.safe_load(open('<path>'))"`), surfaces the common failure modes (unindented heredoc body, missing `|` after `run:`, tab-vs-space mixing), and provides a fix-forward recipe.

## Trigger

**Direct trigger phrases**: "check my workflow YAML", "yaml validate this workflow", "why is dispatch returning trigger error", "dispatch says no workflow_dispatch trigger but it's right there".

**Proactive triggers** (offer without being asked):

- The agent is editing `.github/workflows/*.yml` AND the edit touches a `run: |`, a heredoc (`<<-EOT`, `<<'EOF'`), an embedded Python / Node / jq snippet, or any multi-line `script:` block.
- The agent has just dispatched a workflow and received `"Workflow does not have 'workflow_dispatch' trigger"` from GitHub.
- The agent is committing a workflow file from a sandbox where `python3` is available (every standard Claude Code sandbox).

**Negative triggers** (do NOT activate):

- Editing only frontmatter (`name:`, `on:`, env, permissions) without touching any multi-line block.
- Editing `.yml` files outside `.github/workflows/` (those have different parsers — Kubernetes manifests pass through `yq`/`yaml.safe_load` validation in a separate skill).

## Inputs

- A path to a workflow file (e.g. `.github/workflows/phase-2-diagnose.yml`).
- Optionally, the branch the workflow is intended to dispatch from (to warn about the non-default-branch dispatch behavior described below).

## Outputs

- **Pass case**: prints `OK` and exits 0; no file change.
- **Fail case**: prints the `yaml.scanner.ScannerError` traceback, identifies the offending line number, suggests the most likely cause (unindented heredoc body, indent mismatch, tab-vs-space), and optionally applies a fix if the fix is mechanical (e.g. converting tabs to spaces).

## Workflow

1. **Run the precheck**:
   ```bash
   python3 -c "import yaml; yaml.safe_load(open('<path>')); print('OK')"
   ```
2. **If parse succeeds** → done.
3. **If parse fails**, read the error. The two common signatures from this session:
   - `ScannerError: while scanning a simple key … could not find expected ':'` at column 1 — indicates a multi-line block body has lines starting at column 1 that should be indented. Cause: embedded Python (or other interpreter) heredoc whose body has no leading whitespace; the YAML literal block ended at that line.
   - `could not determine a constructor for the tag '!something'` — indicates a stray `!` interpreted as a YAML tag. Cause: shell history expansion or bash `${!var}` indirect reference inside a `run:` line that's not under `run: |`.
4. **Apply the targeted fix**:
   - For the heredoc-unindented case: either (a) indent the heredoc body to match the surrounding YAML block scalar indent OR (b) rewrite the embedded snippet in pure shell (no heredoc). The session chose (b) in PR #65.
   - For the bash-history-expansion case: switch the offending command to a `run: |` block so the line gets the literal-block treatment.
5. **Re-run the precheck**. Iterate until OK.
6. **If the user dispatched the workflow before validation and got the misleading trigger error**, surface this finding clearly: "the dispatch error is misleading — the actual cause is a YAML parse error on line N".

## Concrete examples

### Example 1 — unindented Python heredoc (from PR #65)

```yaml
      - name: Walk every XR-owned managed resource
        run: |
          kubectl get xplatformsecret "$XR" -o json \
            | python3 -c '
import json, sys, subprocess
xr = json.load(sys.stdin)
…
' || true
```

The Python source lines start at column 1, but the `run: |` block expects everything to be indented to at least the same column as `kubectl`. The YAML literal block terminates at the first column-1 line, leaving the rest of the workflow file mis-parsed.

**Precheck output**:
```
yaml.scanner.ScannerError: while scanning a simple key
  in "<stdin>", line 162, column 1
could not find expected ':'
  in "<stdin>", line 163, column 1
```

**Fix**: rewrite in pure shell using `jsonpath` / `go-template` + `read` + `kubectl`. See PR #65's fix-up commit.

### Example 2 — shell history expansion inside a single-line `run:` (hypothetical)

```yaml
      - name: Print env
        run: echo "PATH=${!PATH}"
```

The `!PATH` is read by YAML as a tag. Precheck output names the offending line. Fix: switch to `run: |` and inline:

```yaml
      - name: Print env
        run: |
          echo "PATH=${!PATH}"
```

## Anti-patterns

- **Skipping the precheck because "the file looks fine".** Heredoc and multi-line scalar bugs are precisely the ones that look fine to the eye.
- **Trusting the GitHub Actions error message.** `"Workflow does not have 'workflow_dispatch' trigger"` is GitHub's catch-all error for unparseable workflows; it is wrong about the cause ~50% of the time when the workflow file has changed recently.
- **Embedding multi-language source (Python, Node, Ruby) inside a YAML literal block when a pure-shell rewrite is feasible.** Each layer of escaping adds a failure mode.
- **Pushing a workflow edit and dispatching immediately to test it.** If the YAML is broken, the dispatch fails with the misleading error and you've wasted a round-trip. Precheck first.

## Acceptance criteria

1. Every push to a `.github/workflows/*.yml` file that touches a multi-line block is preceded by a green `python3 -c "import yaml; yaml.safe_load(open('<path>'))"`.
2. When the precheck fails, the skill's output names the line number and the most likely cause class (unindented heredoc / bash tag / etc.).
3. The skill is idempotent — re-running on a clean file is a no-op.
4. The skill activates proactively when an Edit/Write call touches `.github/workflows/*.yml` in a way that matches the trigger heuristic.

## Files this skill creates / modifies

- Does NOT modify the workflow file unless the user asks for an autofix.
- Optionally writes a `.claude/skills/workflow-yaml-precheck/scripts/check.py` (one-liner wrapper) and wires it into `.claude/settings.json` as a `PreToolUse` hook on `Edit`/`Write` for `.github/workflows/*.yml`.
