# SPEC-LA3 — `scripts/kyverno-decision-explain.sh`

Brainstorm ID: A1-029. Tier A, item LA3.

## 1. Summary

Add `scripts/kyverno-decision-explain.sh <manifest.yaml>` — a read-only
diagnostic helper that accepts any Kubernetes manifest YAML and prints,
for every installed ClusterPolicy, whether the manifest would pass or fail
that policy and the exact violation message when it fails. The script
wraps `kyverno apply` (offline JMESPath evaluation against fetched or
local policy files) and produces human-readable output parallel to
`scripts/kyverno-violations.sh`, targeting a candidate YAML before apply
rather than live cluster state after apply. A golden corpus under
`tests/unit/fixtures/kyverno-explain/` doubles as a regression suite for
policy refactors (brainstorm comment A3→A1-005). The smallest concrete
artifact is one bash script plus three named fixture YAML cases with
sidecar `.expected` files. Orthogonal to SPEC-B4 and all open PRs.

## 2. Retro pain killed

- **PR #64 / Bug 3 (`retrospective/2026-05-25-70.md` line 45):** Kyverno
  injected `spec.background`, `spec.admission`, and the autogen annotation
  onto `crossplane/policies/09-platform-secret-namespace-allowed.yaml`
  because those fields were absent, causing ArgoCD to perceive eternal
  OutOfSync across multiple sessions. Running the explain script against
  the manifest before apply would have surfaced the injected-field
  mismatch before it reached the cluster.

- **Bug 3 recurred across sessions (same retro, line 47):** The
  `test_kyverno_policy_lint.sh §4` lint added in PR #64 enumerates the
  three known drift fields statically. The explain script catches
  additional Kyverno-injected fields generically — without requiring the
  implementer to predict the field set.

- **IRSA SA-name debug loop (retro/2026-05-25-70.md lines 51–59, PRs
  #66–#68):** The SA-vs-trust-subject mismatch was invisible for multiple
  sessions because no tool evaluated the SA manifest against the live
  policy chain before apply. With SPEC-B4's trust-subject policy
  installed, the explain script would have emitted the violation the
  moment the SA manifest was authored.

- **Empty-backtick JMESPath failures in phase 1 apply
  (`test_kyverno_policy_lint.sh` lines 9–13):** A JMESPath error in
  `03-ingress-managed-by-external-dns` was invisible until a full
  management apply failed mid-suite. Running the explain script against
  any ingress fixture would have tripped the same evaluation error before
  any infrastructure was touched.

- **Brainstorm comment A3→A1-005:** "Policy 09 drift recurred; corpus-
  based regression locks behavior." The golden-fixture corpus (§5.3) turns
  each known-good and known-bad input into a permanent unit-push regression
  case.

## 3. Out of scope

- **Does NOT mutate cluster state.** Read-only throughout.
- **Does NOT replace `kyverno-violations.sh`.** That script reads live
  PolicyReports post-apply; this evaluates a candidate pre-apply. Both
  are needed.
- **Does NOT implement the trust-subject check (SPEC-B4).** The script
  evaluates whatever policies are installed; B4 content is B4's
  deliverable.
- **Does NOT automate remediation.** Prints what fails and why; does not
  patch the manifest.

**Considered and rejected:**

- **`kubectl apply --dry-run=server` as the primary path.** Routes through
  the live Kyverno admission webhook, which (a) requires a reachable
  cluster, (b) returns at most one blocking error from the first Enforce
  rule, and (c) is silent on Audit-mode policies. `kyverno apply` offline
  evaluates all policies, including Audit, and emits a structured per-rule
  result. Server dry-run is retained as an opt-in `--server` flag for
  callers who specifically need to probe the live webhook.
- **A kubectl plugin.** Adds installation overhead. A bash script matches
  the existing `scripts/` pattern with no PATH management.

## 4. Files to create / modify

**Create:**

| Path | What |
|------|------|
| `/home/user/k8-platform/scripts/kyverno-decision-explain.sh` | Main script |
| `/home/user/k8-platform/tests/unit/test_kyverno_decision_explain.sh` | Unit test with corpus assertions |
| `/home/user/k8-platform/tests/unit/fixtures/kyverno-explain/sa-irsa-valid.yaml` | SA with well-formed ARN — expects all PASS |
| `/home/user/k8-platform/tests/unit/fixtures/kyverno-explain/sa-irsa-bad-arn.yaml` | SA with malformed ARN — expects FAIL `irsa-rolearn-format` |
| `/home/user/k8-platform/tests/unit/fixtures/kyverno-explain/ingress-no-class.yaml` | Ingress without `spec.ingressClassName` — expects FAIL `ingress-must-have-class` |
| `…/kyverno-explain/*.expected` | One sidecar file per fixture: `PASS` or `FAIL <policy> <rule>` |

**Modify:**

| Path | What |
|------|------|
| `/home/user/k8-platform/scripts/README.md` | Add one-row catalogue entry |
| `/home/user/k8-platform/policies/audit/README.md` | Add "Debugging" section pointing at the script |

## 5. Implementation notes

### 5.1 `kyverno apply` vs `kubectl apply --dry-run=server`

`kyverno apply <policy-files...> --resource <manifest.yaml> -o json`
evaluates all policies — including `validationFailureAction: Audit` — fully
offline and returns a structured per-rule result. This is the primary path
because:

- No live cluster required; works during `phase=test` runs without cluster
  access.
- Per-policy, per-rule output; server dry-run returns only the first
  blocking Enforce failure.
- Audit policies are visible; server dry-run silently passes them.
- The `kyverno` binary is already on the CI PATH (installed via the Kyverno
  Helm release; available locally via `brew install kyverno`).

`kubectl apply --dry-run=server` is exposed as an optional `--server` flag
for callers who need to probe whether the live webhook is reachable, or to
observe mutation-webhook effects before a high-stakes apply. It is not the
default because it requires a healthy cluster and returns an unstructured
error string, not a per-rule breakdown.

### 5.2 Script structure

```bash
#!/usr/bin/env bash
# scripts/kyverno-decision-explain.sh
# Usage: kyverno-decision-explain.sh <manifest.yaml> [--server] [--policy <name>]
#        kyverno-decision-explain.sh --corpus
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
POLICY_DIRS=("$REPO_ROOT/policies/audit" "$REPO_ROOT/crossplane/policies")
TMPDIR_WORK="$(mktemp -d)"; trap 'rm -rf "$TMPDIR_WORK"' EXIT

# Primary path: kyverno apply offline
_fetch_live_policies() {
  kubectl get clusterpolicies.kyverno.io -o yaml 2>/dev/null \
    > "$TMPDIR_WORK/live.yaml" || true
}
_run_explain() {
  local manifest="$1"; shift
  _fetch_live_policies
  local files=()
  for dir in "${POLICY_DIRS[@]}"; do
    [ -d "$dir" ] && files+=("$dir"/*.yaml)
  done
  [ -f "$TMPDIR_WORK/live.yaml" ] && files+=("$TMPDIR_WORK/live.yaml")
  kyverno apply "${files[@]}" --resource "$manifest" -o json 2>/dev/null \
    | python3 "$REPO_ROOT/scripts/_explain_format.py"
}
```

The formatter `_explain_format.py` (~60 lines) reads the kyverno JSON
result envelope and emits:

```
PASS  ingress-must-have-class / ingress-must-have-class
FAIL  irsa-rolearn-format / irsa-arn-must-be-valid
        ServiceAccount default/probe-sa has an eks.amazonaws.com/role-arn
        annotation that does not look like a real IAM role ARN.
```

Exit code: 0 if every evaluated rule passes, 1 if any FAIL. Context-
load errors (e.g., a policy requiring `context.configMap` not available
offline) emit `SKIP (context unavailable)` and do not count toward exit 1,
preventing false positives against SPEC-B4's trust-subject policy when
the ConfigMap is absent.

### 5.3 Corpus mode

`--corpus` iterates every `tests/unit/fixtures/kyverno-explain/*.yaml`
fixture, runs the explain script against each, diffs the output against
the sidecar `.expected` file, and prints OK/FAIL per case. The `.expected`
format is `PASS` (all rules pass) or one `FAIL <policy> <rule>` line per
failing rule. Stable for `diff`-based comparison; readable enough to
author by hand. Running `--corpus` inside `unit-tests.yml` turns any
policy refactor that changes fixture outcomes into an immediate red unit
suite.

### 5.4 Performance

`kyverno apply` for one manifest against 10 policies: under 3 seconds.
Full corpus run (three initial fixtures): under 10 seconds. Both fit the
unit-test budget in `unit-tests.yml`.

## 6. Tests required

Per AGENTS.md §6.1, two layers gate this spec:

| Layer | File | Assertion |
|-------|------|-----------|
| Unit | `tests/unit/test_kyverno_decision_explain.sh` | `--corpus` exits 0, all three fixtures match `.expected` |
| Unit | same | `sa-irsa-bad-arn.yaml` → exit 1, stdout contains `irsa-rolearn-format` |
| Unit | same | `sa-irsa-valid.yaml` → exit 0, no FAIL lines |
| Unit (meta-test) | same | Corrupt `sa-irsa-valid.expected`; confirm `--corpus` exits 1 naming the fixture; restore |

The meta-test is the gate: it proves the diff comparison fires on
expectation violations, not just on fixture content that happens to pass.

Per AGENTS.md §6.4, before drafting tests the implementing agent dispatches
one adversarial subagent with the four-part brief from §6.4, including the
context-unavailable SKIP path (§5.2) as a known edge case.

## 7. Testing suggestions (unit / integration / e2e)

**Unit** — `tests/unit/test_kyverno_decision_explain.sh`, <10 s each.

1. Corpus baseline — all three fixtures match `.expected`; no regression
   from initial implementation.
2. Bad-ARN FAIL — `sa-irsa-bad-arn.yaml` exits 1 with `irsa-rolearn-format`
   named.
3. Ingress-class FAIL — `ingress-no-class.yaml` exits 1 with
   `ingress-must-have-class` named.
4. Valid SA all-pass — `sa-irsa-valid.yaml` exits 0, zero FAIL lines.
5. Context-unavailable SKIP — a policy fixture containing a
   `context.configMap` stanza with no cluster available produces `SKIP`
   output and exit 0 (not a failure).

These extend §6; they are the broader regression catalogue as new policies
land.

**Integration** — `tests/integration/NN_kyverno_explain.sh`, live cluster.

1. Live policy fetch — `--corpus` against the cluster's installed policies
   (not local YAML files); assert all three fixture outcomes still match.
   Catches drift between local policy files and installed policies.
2. `--server` path — evaluate `sa-irsa-bad-arn.yaml` with `--server`;
   assert admission error appears in stderr and exit code is 1. Proves
   the fallback path reaches the live webhook.
3. Phase-2 fixture — once phase 2 is applied, add a PlatformSecret Claim
   YAML fixture; assert `09-platform-secret-namespace-allowed` evaluates
   correctly for allowed vs disallowed namespaces.

**E2E** — not applicable for this spec at time of authoring. The script is
a local diagnostic helper; its contracts are fully covered at unit and
integration layers. A chainsaw scenario that calls the explain script as a
pre-apply assertion step is a follow-on item (`tests/chainsaw/<scenario>/
00-explain-precheck/`); no such scenario is required to ship this spec.

## 8. Documentation updates

- `/home/user/k8-platform/scripts/README.md` — one catalogue row:
  `kyverno-decision-explain.sh <manifest.yaml>` — per-rule pass/fail
  before apply.
- `/home/user/k8-platform/policies/audit/README.md` — "Debugging" section:
  "To check which policies a manifest would violate before applying, run
  `scripts/kyverno-decision-explain.sh <manifest.yaml>`."
- `/home/user/k8-platform/ai/testing-guidelines.md` — add one line under
  pre-apply sanity tools; cite LA3.
- `AGENTS.md` — no change needed; the script is convenience, not a
  mandatory gate. If adversarial review (§6.4) elevates it to a required
  pre-apply step, update §6.1 at that time.

## 9. Workflow / auto-invocation wiring

Manual invocation for debugging; automated only via corpus mode inside
`unit-tests.yml`. The corpus mode fires on every push through
`tests/unit/run.sh`, which auto-discovers `test_*.sh` files. A policy
refactor that changes evaluation output on any fixture turns the unit
suite red immediately, naming the mismatched fixture. No pre-commit hook
is wired; authors who want local protection can invoke `--corpus` directly.

## 10. Discoverability

1. **Mechanical enforcement** — corpus mode runs in `unit-tests.yml` on
   every push. A policy refactor that flips any fixture outcome turns the
   unit suite red and names the fixture and the expected vs actual diff.
2. **Documentation pointer** — `policies/audit/README.md` gains a
   "Debugging" section; `scripts/README.md` lists the script alongside
   `kyverno-violations.sh`. An agent scanning the audit README or the
   scripts catalogue finds both tools in one read.
3. **Adversarial-review trigger** — AGENTS.md §6.4's coverage check "does
   the plan cover the pre-apply evaluation surface?" gates any new-policy
   PR. A test plan for a new ClusterPolicy that omits a fixture in
   `tests/unit/fixtures/kyverno-explain/` fails the adversarial reviewer's
   coverage check, because the corpus is the canonical authoring-time
   regression test for policy semantics.

## 11. Verification checklist

- [ ] `bash scripts/kyverno-decision-explain.sh --help` prints usage
  containing `<manifest.yaml>` and exits 0.
- [ ] `bash scripts/kyverno-decision-explain.sh tests/unit/fixtures/kyverno-explain/sa-irsa-bad-arn.yaml`
  exits 1 and stdout contains `FAIL` and `irsa-rolearn-format`.
- [ ] `bash scripts/kyverno-decision-explain.sh tests/unit/fixtures/kyverno-explain/sa-irsa-valid.yaml`
  exits 0 and stdout contains no `FAIL` lines.
- [ ] `bash scripts/kyverno-decision-explain.sh tests/unit/fixtures/kyverno-explain/ingress-no-class.yaml`
  exits 1 and stdout contains `ingress-must-have-class`.
- [ ] `bash scripts/kyverno-decision-explain.sh --corpus` exits 0, all
  three fixture cases print OK.
- [ ] Temporarily corrupt `sa-irsa-valid.expected` to `FAIL dummy rule`;
  confirm `--corpus` exits 1 and names the fixture; restore the file.
- [ ] `bash tests/unit/test_kyverno_decision_explain.sh` exits 0 with all
  assertions passing.
- [ ] `bash tests/unit/run.sh` exits 0 with `test_kyverno_decision_explain`
  appearing in the output.
- [ ] `[ -x scripts/kyverno-decision-explain.sh ]` succeeds (file is
  executable).
- [ ] `shellcheck scripts/kyverno-decision-explain.sh` exits 0 or produces
  only suppressable SC2 warnings per existing repo convention.

## 12. Rollout notes

- **Backward compatibility:** new script and new fixture directory cannot
  break any existing flow. The only risk is corpus test going red if
  `kyverno` CLI flag behavior differs on the CI runner; calibrate during
  implementation smoke test.
- **Audit-before-merge:** no existing files require changes to pass the
  new test. Confirm `tests/unit/run.sh` auto-discovers `test_*.sh` by
  grepping its glob; if not, add an explicit line.
- **Sandbox constraints:** entirely local — no EC2, no Bedrock, no
  Marketplace. The `kyverno` binary is a static Go binary from public
  GitHub releases; no new quota consumed.
- **In-flight branches:** orthogonal to all open PRs. Couples loosely with
  SPEC-B4: once B4 lands, add a trust-subject fixture to the corpus in a
  follow-on PR, not a blocker.
- **Branch sequencing:** land on `feat/kyverno-decision-explain` off
  `main` as a standalone PR; no stacking dependency.

## 13. Estimated effort

**S** — small (≤1 hr).

The bash scaffolding mirrors `scripts/kyverno-violations.sh`. The
`kyverno apply -o json` invocation is well-documented; the Python
formatter is ~60 lines. Three fixture YAML files are copy-edits from
existing unit fixtures. The unit test file is three assertion calls plus
a five-line corpus meta-test setup/teardown. README edits are two short
bullets. A single local `--corpus` smoke run calibrates the expected
output format. No cluster apply, no IAM change, no workflow dispatch.
Breakdown: script authoring 20 min, fixtures + test file 15 min, README
edits 5 min, smoke test 10 min, rollout audit 5 min.
