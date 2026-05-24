# Spec: `chainsaw-script-dialect-awareness`

- **ID**: SKILL-SPEC-085176fac1
- **Source retrospective**: ../2026-05-24-62.md

## Intent

Chainsaw's `script:` step runs with `/usr/bin/sh`, not bash. On Ubuntu 24.04 GH-hosted runners that's `dash`, which does NOT support `set -o pipefail` and several other bashisms. Additionally, Crossplane's XRD `status.conditions` array order is non-deterministic, so positional asserts in chainsaw `assert:` blocks are unreliable for those resources. This skill captures both gotchas as enforceable patterns.

Grounded in: PR #53 hit both bugs across four chainsaw iterations before they were rooted out. Each iteration cost ~7 minutes of CI. Bug-of-records: chainsaw run 26346566417 (`sh: 1: set: Illegal option -o pipefail`), runs 26346745818 and 26346974750 (XRD conditions in different orders).

## Trigger

**Direct user phrases:**
- "Author a chainsaw scenario"
- "Add a chainsaw test"
- "Fix the chainsaw script"

**Proactive triggers:**
- About to write a chainsaw `Test` scenario YAML
- About to write a `script:` block inside chainsaw
- About to write an `assert:` block that targets `status.conditions` of a Crossplane-managed object

**Negative triggers:**
- Editing `tests/chainsaw/run.sh` (that runs in bash, not chainsaw script: context)
- Authoring an integration test under `tests/integration/` (those are bash scripts, not chainsaw scripts)

## Inputs

- The chainsaw test file path (`tests/chainsaw/<scenario>/chainsaw-test.yaml`)
- The intent of the script: block (assertion, setup, side-effect)
- The kind of resource being asserted on (Crossplane XRD vs plain Kubernetes)

## Outputs

- chainsaw test YAML with:
  - `set -eu` (or `set -e`) — NOT `set -euo pipefail` — in every script: block
  - No bashisms (`[[ ]]`, `${var:?}`, arrays, process substitution) in script: blocks
  - `kubectl wait --for=condition=` instead of positional `assert: status.conditions[N]` for non-deterministic-order resources (Crossplane XRDs, Compositions, ESO ExternalSecrets)

## Workflow

1. **Before writing a chainsaw `script:` block,** ask:
   - Does this need pipefail? If yes, you're using pipes — rewrite to avoid them OR move the logic into a bash sidecar in run.sh, NOT in the chainsaw script.
   - Does this use any bashism? If yes, rewrite POSIX-compatible.

2. **Use `set -eu` only.** Never `set -euo pipefail` in chainsaw script blocks.

3. **Before writing a chainsaw `assert:` block on `status.conditions`,** ask:
   - Is the target resource managed by a controller that emits conditions in deterministic order?
     - Plain Kubernetes (Pods, Deployments, etc.) — deterministic, `assert:` is fine
     - Crossplane (XRDs, XRs, Compositions, Functions) — **non-deterministic**, use `kubectl wait`
     - ESO (ExternalSecret, ClusterSecretStore) — **non-deterministic**, use `kubectl wait`
     - Kyverno (ClusterPolicy, PolicyReport) — non-deterministic, use `kubectl wait`

4. **For non-deterministic targets**, replace `assert:` blocks with `script:` blocks using kubectl wait:
   ```yaml
   - name: assert XRD reaches Established + Offered
     try:
       - script:
           content: |
             set -eu
             kubectl wait --for=condition=Established --timeout=60s xrd/<name>
             kubectl wait --for=condition=Offered     --timeout=60s xrd/<name>
   ```

5. **For deterministic targets** (Pods, Services), `assert:` is still fine.

6. **Test locally if possible:** run the harness via `bash tests/chainsaw/run.sh` after editing. If kind/chainsaw aren't installed locally, dispatch the chainsaw workflow against the branch SHA per `dispatch-then-poll-then-readlog`.

## Concrete examples

### Example 1 — XRD establishment assert (the actual fix in PR #53)

**Anti-example (failed twice):**
```yaml
- name: assert XRD is Established
  try:
    - assert:
        resource:
          ...
          status:
            conditions:
              - type: Established       # WRONG: order varies
                status: "True"
              - type: Offered
                status: "True"
```

**Correct (the fix):**
```yaml
- name: assert XRD reaches Established + Offered
  try:
    - script:
        content: |
          set -eu   # NOT set -euo pipefail
          kubectl wait --for=condition=Established --timeout=60s \
            xrd/xplatformclusters.platform.k8-platform.io
          kubectl wait --for=condition=Offered --timeout=60s \
            xrd/xplatformclusters.platform.k8-platform.io
```

### Example 2 — schema validation script (the pipefail fix)

**Anti-example:**
```yaml
- name: assert invalid claim rejected
  try:
    - script:
        content: |
          set -euo pipefail    # sh: Illegal option -o pipefail
          if kubectl apply --dry-run=server -f - <<'YAML' 2>/tmp/err.log
          ...
```

**Correct:**
```yaml
- name: assert invalid claim rejected
  try:
    - script:
        content: |
          set -eu                # POSIX-safe
          if kubectl apply --dry-run=server -f - <<'YAML' 2>/tmp/err.log
          ...
```

## Anti-patterns

- **`set -o pipefail` in chainsaw script blocks** — silently dies on dash.
- **Bashism `[[ ... ]]`** — use POSIX `[ ... ]`.
- **Bash arrays** — use space-separated strings + `for x in $list`.
- **Process substitution `<(cmd)`** — use temp files.
- **Positional `assert:` on Crossplane status.conditions** — order non-deterministic, asserts fail randomly.

## Acceptance criteria

1. Every chainsaw `script:` block uses `set -eu` (never `set -euo pipefail`).
2. Every chainsaw `script:` block contains only POSIX-sh-compatible code.
3. Every `status.conditions` assertion on Crossplane / ESO / Kyverno resources uses `kubectl wait`, not positional `assert:`.
4. Plain Kubernetes resource conditions still use `assert:` where deterministic.
5. A lint at `tests/unit/test_chainsaw_script_dialect.sh` flags violations.

## Files this skill creates / modifies

- `tests/chainsaw/<scenario>/chainsaw-test.yaml` (per scenario)
- (Future) `tests/unit/test_chainsaw_script_dialect.sh` — a new lint enforcing this skill's invariants
