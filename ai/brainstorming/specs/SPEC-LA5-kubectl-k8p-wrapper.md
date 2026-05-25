# SPEC-LA5 — `kubectl k8p <subcmd>`: krew-style wrapper for all debug commands

## 1. Summary

Add a single krew-style binary `kubectl-k8p` on `PATH` so that operators
and agents can run `kubectl k8p <subcmd>` instead of discovering and
invoking individual scripts under `scripts/`. The binary dispatches to
six backend scripts authored by earlier specs: `status` (SPEC-S5
`scripts/phase-status.sh`), `claim` (SPEC-S2
`scripts/crossplane-trace.sh`), `secret` (SPEC-LA2
`scripts/eso-trace.sh`), `irsa` (SPEC-S3
`scripts/irsa_trust_validator.py`), `syncwave` (SPEC-LA7
`scripts/argocd-syncwave-view.sh`), and a raw `help` built-in. The
wrapper is a single Bash script at
`/home/user/k8-platform/scripts/kubectl-k8p` that forwards all
positional arguments and the calling environment to the appropriate
backend. It carries its own `--help` and per-subcmd `--help` so the
README "common commands" section is no longer the authoritative surface
— the wrapper replaces it. Brainstorm ID A1-033; comment A6→A1-011
explicitly designates the wrapper as superseding the README. Tier A item
LA5 in `ai/brainstorming/specs/larger-list-preferences.md`. This spec
**must land last** in Tier A, after SPEC-S2, SPEC-S3, SPEC-S5, SPEC-LA2,
and SPEC-LA7 deliver the scripts it dispatches to.

## 2. Retro pain killed

- **README "common commands" is a dead-end link chain.**
  `ai/brainstorming/A1-debug-tools-max-capability.md` cross-comment
  A6→A1-011: *"The `kubectl k8p` krew-style wrapper (A1-033) supersedes
  the README 'common commands' section — make the wrapper
  self-documenting."* Prior sessions opened `scripts/README.md`, read
  the inventory table, and still had to read each script's `--help`
  separately. One entry point eliminates that indirection.

- **Script proliferation cost per session.** `scripts/` currently has
  eight scripts with distinct invocation shapes; Tier S and Tier A add
  five more. Without a unified entry point a new session must re-read
  `scripts/README.md` each time. This is the cognitive cost A1-033
  cites: *"Discoverable surface; lowers cognitive cost."*

- **Agents rediscovering debug paths mid-session.**
  `retrospective/2026-05-25-70.md` Phase 2 documents a session where
  the agent dispatched a workflow to run diagnostics because the direct
  script path was not on its mental map. A single `kubectl k8p` surface
  can be cited in AGENTS.md and reliably located across sessions.

- **`scripts/README.md` silently out of date.** New backend scripts must
  be manually added to the README. The wrapper's `_k8p_help` output is
  defined in the `case` registry, so extending the wrapper is the single
  maintenance point.

## 3. Out of scope

- **Adding new diagnostic capabilities.** The wrapper dispatches to
  existing backends only. No new kubectl output, no new AWS API calls.
  New diagnostic logic belongs in the backend scripts.

- **krew publication.** This spec installs `kubectl-k8p` on the local
  PATH via a symlink or `scripts/install.sh` step. Publishing to the
  official krew index is out of scope for this project.

- **Auto-completion (bash/zsh).** Completion scripts add a non-trivial
  surface (one per shell). Defer — the `--help` output is sufficient for
  one-operator / one-agent use.

- **Windows / PowerShell compatibility.** All backend scripts are Bash;
  the wrapper is Bash. Not applicable in this project's Linux sandbox
  and GitHub Actions runners.

- **Background execution / pipelining.** Brainstorm comment A5→A1-008
  proposes launching subcommands in background by default (returning a
  handle). Deferred: background invocation semantics interact with TTY
  detection and signal forwarding in non-obvious ways. It can be added
  per-subcmd in a follow-on PR without changing the wrapper's dispatch
  contract.

- **Replacing existing `scripts/*.sh` symlinks.** The backend scripts
  remain independently invocable; the wrapper is an additional entry
  point, not a rename.

### Considered and rejected

- **Python wrapper instead of Bash.** A Python dispatcher could use
  importlib to discover subcommands dynamically. Rejected because all
  backends are Bash; adding a Python layer just to dispatch introduces a
  Python interpreter dependency where none exists today. Bash `exec`
  dispatch is three lines.

- **Makefile target `make k8p status`.** Rejected: `make` is not
  available on all operator machines; krew-style `kubectl` plugin is the
  idiomatic and most discoverable entry point for Kubernetes operators.

- **Embedding backend logic directly in the wrapper.** Rejected: the
  backends are authored and tested independently (SPEC-S2, SPEC-S3,
  SPEC-S5, SPEC-LA2, SPEC-LA7). Inlining them in the wrapper creates
  a single-file maintenance burden and defeats the per-spec test
  coverage each backend carries.

## 4. Files to change / create

**Create:**

- `/home/user/k8-platform/scripts/kubectl-k8p` — the dispatcher binary
  (Bash, `chmod +x`). Primary deliverable.
- `/home/user/k8-platform/tests/unit/test_kubectl_k8p.sh` — unit test
  (validates dispatch routing, help text, unknown-subcmd error).

**Modify:**

- `/home/user/k8-platform/scripts/README.md` — replace the static
  inventory table with a pointer to `kubectl k8p --help` as the
  authoritative surface; add the bootstrap one-liner for installing the
  symlink.
- `/home/user/k8-platform/AGENTS.md` — add a bullet under the
  `scripts/` section (§11 file layout) pointing agents at
  `kubectl k8p --help` instead of the README inventory.
- `/home/user/k8-platform/docs/operations.md` (if present; otherwise
  `scripts/README.md` is sufficient) — replace or supplement any
  "common commands" section.

**No other files are touched.** Backend scripts, CI workflows, Terraform,
Crossplane manifests, and ArgoCD applications are all out of scope.

## 5. Implementation notes

### 5.1 Binary layout and dispatch

`scripts/kubectl-k8p` is a Bash script (`chmod +x`). kubectl discovers
plugins by searching PATH for executables named `kubectl-<name>`; adding
`scripts/` to PATH (see §5.3) enables `kubectl k8p` invocation.

Key shape:

```bash
#!/usr/bin/env bash
set -euo pipefail
# Resolve real script dir even when invoked via symlink.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBCMD="${1:-help}"; shift || true
case "$SUBCMD" in
  status)   exec "$SCRIPT_DIR/phase-status.sh"         "$@" ;;
  claim)    exec "$SCRIPT_DIR/crossplane-trace.sh"     "$@" ;;
  secret)   exec "$SCRIPT_DIR/eso-trace.sh"            "$@" ;;
  irsa)     exec python3 "$SCRIPT_DIR/irsa_trust_validator.py" "$@" ;;
  syncwave) exec "$SCRIPT_DIR/argocd-syncwave-view.sh" "$@" ;;
  help|--help|-h) _k8p_help ;;
  *) echo "k8p: unknown subcommand '$SUBCMD'" >&2; exit 1 ;;
esac
```

`_k8p_help` prints one line per subcmd (name + one-sentence description)
drawn from a static associative array. This keeps the help text in sync
with the registered subcmds without parsing backends.

`exec` replaces the wrapper process entirely — no subprocess overhead,
environment variables (`$KUBECONFIG`, `$AWS_REGION`) inherited without
copying. On unknown subcmd: stderr message, exit 1.

### 5.2 Installation

Preferred in CI and ephemeral sessions:
```sh
export PATH="/home/user/k8-platform/scripts:$PATH"
```
Alternative: `ln -sf .../scripts/kubectl-k8p /usr/local/bin/kubectl-k8p`.
The unit test uses the `export PATH` form to avoid requiring root.

### 5.3 Extensibility — how to add a new subcommand

To add subcmd `foo` dispatching to `scripts/foo-diag.sh`:

1. Author `scripts/foo-diag.sh` with `--help`; `chmod +x`.
2. Add one `case` arm: `foo) exec "$SCRIPT_DIR/foo-diag.sh" "$@" ;;`
3. Add one entry to the `SUBCMDS` array in `_k8p_help`.
4. Add a routing assertion for `foo` in `test_kubectl_k8p.sh`.
5. Update `scripts/README.md`.

No registration file, no plugin manifest. The `case` statement is the
registry; adding a line is the entire extension protocol.

## 6. Tests required

Per AGENTS.md §6.1, tests must ship in the same PR.

| Layer | File | Assertion |
|---|---|---|
| Unit | `/home/user/k8-platform/tests/unit/test_kubectl_k8p.sh` | `kubectl k8p help` exits 0; stdout contains all five subcmd names. |
| Unit | same | `kubectl k8p unknown-subcmd` exits 1; stderr contains `unknown subcommand`. |
| Unit | same | Stub `phase-status.sh` prints `STUB-STATUS`; `kubectl k8p status` stdout contains `STUB-STATUS`. Proves dispatch reached the right backend. |
| Unit | same | Stub `crossplane-trace.sh` prints `STUB-CLAIM`; `kubectl k8p claim` stdout contains `STUB-CLAIM`. |
| Unit | same | `kubectl k8p` (no args) exits 0 and stdout contains the subcmd list (default-to-help). |

Adversarial review (AGENTS.md §6.4): spawn one general-purpose subagent
before finalising tests. Brief: five files shipped (wrapper + unit test
+ three doc edits), the plan above, known failure class (`SCRIPT_DIR`
resolution wrong under symlink), §6.4 job text verbatim, non-goal:
*"we are not testing individual backend scripts."*

## 7. Testing suggestions

### Unit

`tests/unit/test_kubectl_k8p.sh` — fast, no cluster needed:

1. `kubectl k8p help` exits 0 and stdout contains all five subcmd names.
2. Stub `phase-status.sh` to print `STUB-STATUS`; assert `kubectl k8p
   status` stdout contains `STUB-STATUS` (routing confirmed without a
   live cluster).
3. Same stub pattern for `crossplane-trace.sh` → `claim` subcmd.
4. `kubectl k8p notasubcmd` exits 1 and stderr contains `unknown
   subcommand`.
5. `kubectl k8p` (no args) exits 0 and stdout contains the subcmd list
   (defaults to help).
6. Symlink test: create `/tmp/testbin/kubectl-k8p → .../scripts/kubectl-k8p`,
   add to PATH, invoke. Assert it finds stubs via `BASH_SOURCE[0]`
   resolution — guards the `dirname $0` vs symlink class of bug.

### Integration

`tests/integration/14_k8p_status_smoke.sh` — requires live cluster:
`kubectl k8p status` exits 0 and output contains at least one phase
label (`phase-0` or `phase-1`).

`tests/integration/15_k8p_irsa_smoke.sh`: `kubectl k8p irsa --all` exits
0 and output contains at least one `MATCH` or `MISMATCH` line.

Integration tests for `claim`, `secret`, and `syncwave` belong to their
backend specs (SPEC-S2, SPEC-LA2, SPEC-LA7) and are not duplicated here
— the wrapper dispatch is covered by unit stubs.

### E2E

Not applicable — deliberate scoping decision. The wrapper is a thin
dispatcher; all E2E diagnostic behaviour lives in the backends. A
chainsaw scenario invoking `kubectl k8p claim` would duplicate SPEC-S2's
existing chainsaw coverage. The wrapper adds discoverability, not new
capability.

## 8. Documentation updates

- `/home/user/k8-platform/scripts/README.md` — replace the static
  inventory table "Inventory" section with a pointer paragraph:
  *"The canonical entry point for all debug commands is `kubectl k8p
  <subcmd>`. Run `kubectl k8p help` for the current subcmd list. The
  table below is preserved for users who invoke scripts directly."*
  Add the `export PATH=...` bootstrap one-liner.

- `/home/user/k8-platform/AGENTS.md` §11 (file layout, `scripts/` row)
  — add parenthetical: *"(canonical entry point: `kubectl k8p
  <subcmd>` — run `kubectl k8p help`)"*.

- `/home/user/k8-platform/ai/testing-guidelines.md` — add one bullet
  under the "scripts/" section (if present): *"New debug scripts MUST
  register a `case` arm in `scripts/kubectl-k8p` and update its
  `_k8p_help` table as part of the same PR."*

- `/home/user/k8-platform/docs/operations.md` — if a "common commands"
  section exists, replace it with a `kubectl k8p help` invocation
  reference and remove the static command list.

## 9. Workflow / auto-invocation wiring

The wrapper is a **manually-invoked runbook tool**; it is not
auto-invoked by pre-commit hooks, CI workflows, or skill activation
phrases. Auto-invocation does not make sense for a diagnostic dispatcher
— the agent or operator chooses when to run it based on the failure mode
being diagnosed.

The `tests/unit/test_kubectl_k8p.sh` test is auto-discovered by
`tests/unit/run.sh` and therefore runs on every push via
`.github/workflows/unit-tests.yml`. This is the only automated gate.

Skill activation: the `crossplane-claim-verify` skill (AGENTS.md §7) may
reference `kubectl k8p claim` as the canonical invocation once the
wrapper and backends are both landed. That update belongs to the skill's
own `SKILL.md` edit, not to this spec.

## 10. Discoverability

1. **Mechanical enforcement.** `tests/unit/test_kubectl_k8p.sh` runs on
   every push (auto-discovered by `tests/unit/run.sh` → triggered by
   `.github/workflows/unit-tests.yml`). A PR that adds a new subcmd
   without registering the `case` arm and updating `_k8p_help` will
   pass the unit tests but miss the new routing assertion. To prevent
   silent omissions, `test_kubectl_k8p.sh` includes an explicit
   assertion that the five documented subcmds are all routable — so a
   future agent cannot remove a subcmd arm without the test going red.
   Additionally, `ai/testing-guidelines.md` (per §8 above) requires
   every new debug script to register in the wrapper, making the
   registration step part of the spec acceptance criteria.

2. **Documentation pointer.** AGENTS.md §11 (file layout) will contain
   the parenthetical `"(canonical entry point: kubectl k8p <subcmd>)"`.
   Any agent reading §11 to locate a debug script lands on the wrapper
   first.

3. **Adversarial-review trigger.** The §6.4 adversarial-review checklist
   for new debug scripts should include: *"Does this script register a
   `kubectl k8p` subcmd arm? Is the arm tested in
   `test_kubectl_k8p.sh`?"* Add this as a bullet to
   `ai/testing-guidelines.md §6.4`.

## 11. Verification checklist

Concrete commands the implementing agent runs after coding this spec:

- [ ] `chmod +x /home/user/k8-platform/scripts/kubectl-k8p` then
  `export PATH="/home/user/k8-platform/scripts:$PATH"` then
  `kubectl k8p help` — exits 0, stdout lists all five subcmds.
- [ ] `kubectl k8p help 2>&1 | grep -E "status|claim|secret|irsa|syncwave"` —
  all five names present.
- [ ] `kubectl k8p unknown 2>&1; echo "exit:$?"` — stderr contains
  `unknown subcommand`, exit code is 1.
- [ ] `kubectl k8p status --help 2>&1 | head -5` — output matches what
  `scripts/phase-status.sh --help` produces (same text, proving
  dispatch happened not wrapper-generated text).
- [ ] `bash tests/unit/test_kubectl_k8p.sh` — exits 0, prints PASS for
  each assertion.
- [ ] `bash tests/unit/run.sh` — exits 0 and includes
  `test_kubectl_k8p.sh` in the discovered test list.
- [ ] Symlink test: `ln -sf /home/user/k8-platform/scripts/kubectl-k8p
  /tmp/k8p-link` then `/tmp/k8p-link help` — exits 0, same output as
  direct invocation (validates `BASH_SOURCE[0]` resolution).
- [ ] `grep -c "kubectl k8p" /home/user/k8-platform/scripts/README.md`
  returns ≥ 1 (README updated).
- [ ] `grep -c "kubectl k8p" /home/user/k8-platform/AGENTS.md`
  returns ≥ 1 (AGENTS.md updated).
- [ ] `wc -l /home/user/k8-platform/scripts/kubectl-k8p` returns ≤ 70
  (wrapper stays thin; logic stays in backends).

## 12. Rollout notes

**This spec must land LAST among Tier A items.** The wrapper dispatches
to five backend scripts whose existence it assumes:

| Subcmd | Backend script | Authored by |
|---|---|---|
| `status` | `scripts/phase-status.sh` | SPEC-S5 |
| `claim` | `scripts/crossplane-trace.sh` | SPEC-S2 |
| `secret` | `scripts/eso-trace.sh` | SPEC-LA2 |
| `irsa` | `scripts/irsa_trust_validator.py` | SPEC-S3 |
| `syncwave` | `scripts/argocd-syncwave-view.sh` | SPEC-LA7 |

If any of these backends is absent, the corresponding `exec` will fail
with `No such file or directory`. The unit tests use stubs to isolate
the wrapper from live backends during testing, but the real integration
smoke tests (`14_k8p_status_smoke.sh`, `15_k8p_irsa_smoke.sh`) require
live backends. Do not open the PR for this spec until all five backends
are merged to `main`.

**Backward compatibility.** The wrapper is purely additive. It creates a
new executable and modifies three documentation files. No existing script
is renamed, no test is deleted, no CI workflow path changes. Operators
who invoke `scripts/phase-status.sh` directly continue to work.

**Audit-before-merge.** No existing file requires compliance fixes to
pass the new unit test — the test is scoped entirely to the wrapper and
its stubs.

**Pluralsight sandbox constraints** (us-east-1/us-west-2, t-class,
≤9 EC2, no Bedrock/Marketplace): orthogonal. The wrapper and its unit
tests are pure Bash with no AWS API calls, no cluster resources, and no
cloud cost.

**Coordination with in-flight branches.** Because this spec lands last,
branch off `main` after SPEC-S5, SPEC-S2, SPEC-LA2, SPEC-S3, and
SPEC-LA7 are all merged. No stacking required if the sequencing is
respected. If a backend spec is in review but not yet merged, do not
stack this spec on top of it — wait for the merge so the integration
smoke tests pass against real backends.

**Branch sequencing per CLUSTERING-REVIEW.md.** The 15-spec cluster
review does not include SPEC-LA5 (it postdates that review); no
cluster-assigned sequencing conflict exists.

## 13. Estimated effort

**S** (≤1 hour).

The wrapper itself is ≤ 70 lines of Bash with no novel logic — a
`case` dispatch, a help function, and a `SCRIPT_DIR` resolver. The unit
test is ≤ 80 lines with stub setup. Three documentation edits are each
one paragraph or one table row.

Breakdown:

- Wrapper authoring: ~20 min (Bash `case` dispatch + `_k8p_help`).
- Unit test authoring including stub harness: ~25 min.
- Three doc edits (scripts/README.md, AGENTS.md, testing-guidelines):
  ~10 min.
- §6.4 adversarial-review pass (one subagent, small addition): ~10 min
  to dispatch + adopt suggestions.
- §11 checklist smoke run: ~10 min.

Total: ~75 min, solidly within the `S` band. The only non-trivial risk
is the symlink `BASH_SOURCE[0]` resolution; budget an extra 15 min if
the first smoke run fails that check.
