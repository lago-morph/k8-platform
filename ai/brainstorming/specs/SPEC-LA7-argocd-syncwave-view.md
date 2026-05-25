# SPEC-LA7 — `scripts/argocd-syncwave-view.sh <app>`: print resources in sync-wave order with status

Brainstorm ID: A1-043. Tier A.

## 1. Summary

Add a single read-only diagnostic script,
`/home/user/k8-platform/scripts/argocd-syncwave-view.sh`, that accepts an
ArgoCD Application name, fetches the live resource tree from the cluster,
reads each resource's `argocd.argoproj.io/sync-wave` annotation, and prints a
sorted table — wave number, resource kind/name/namespace, sync status, and
health status — so an operator can see the exact ordering ArgoCD will use
(and is currently using) in one glance. The script depends on
`scripts/_lib/k8s-helpers.sh` for shared kubectl-check and color-output
helpers. Phase 3+ will introduce multi-wave apps (ingress-nginx, ExternalDNS,
cert-manager all managed by a new App-of-apps tier); a dedicated wave-viewer
prevents the same ordering confusion that stalled phase 2a (PR #52, PR #59).
The smallest concrete artifact is one bash script under
`/home/user/k8-platform/scripts/` and one unit-test file under
`/home/user/k8-platform/tests/unit/`.

## 2. Retro pain killed

- **PR #52 / bootstrap-order bug** — `retrospective/2026-05-24-62.md`
  Phase 1: the Kyverno audit policy `policies/audit/09-platform-secret-
  namespace-allowed.yaml` was applied by Terraform before ArgoCD had synced
  the `PlatformSecret` XRD (wave 0). Five-step debug cycle to discover the
  policy lived outside the sync-wave ordering. A wave-view of the
  `crossplane-resources` Application would have shown wave 0 = XRDs,
  wave 1 = policies and surfaced the gap immediately.
- **Sync-wave cascade timing race** — `retrospective/2026-05-24-62.md` §6.X
  suggestion: "ArgoCD's default refresh interval is 3 min; sync-wave cascades
  are serial. 'Just dispatched, immediately polling' creates a race condition."
  Without visibility into the cascade order, operators guessed which wave was
  stalling. The script makes the order explicit.
- **ClusterSecretStore ordering dependency** — `argocd/apps/crossplane-
  resources.yaml` header: "The ClusterSecretStore (in management-cluster-
  config) MUST be Ready BEFORE any PlatformSecret claim renders an
  ExternalSecret; the parent app sync-wave on management-cluster-config (-10)
  vs this app (0) enforces that." This relationship is documented in a comment;
  it is not observable without reading two separate YAML files. The wave-view
  surfaces both apps and their relative ordering in one output.
- **PR #59 / integration test silence** — `retrospective/2026-05-24-62.md`
  Phase 5: four `wait_for` timeouts were invisible because the script reported
  PASS. Part of the root cause was ordering confusion: tests polled resources
  before ArgoCD's wave cascade had completed. The wave-view exposes which
  resources are in which wave so a test author knows the minimum wait.
- **Phase 3+ growth** — brainstorm entry A1-043: "sync-wave bugs in phase 2a
  were painful; this surfaces order." `platform-cluster-claim` is already at
  wave 10; more phase-3 apps deepen the cascade each phase.

## 3. Out of scope

- **No ArgoCD CLI dependency.** The script uses `kubectl get application` +
  `kubectl get <resource>` only. The `argocd` CLI requires authenticated
  sessions and port-forwarding that are not reliable in the Pluralsight
  sandbox or in CI chainsaw runners; pure kubectl is always available.
- **No mutation.** The script is strictly read-only. Triggering a sync,
  changing wave annotations, or pausing an app is not in scope.
- **No cross-app ordering.** The app-of-apps bootstrap wave ordering
  (e.g., `management-cluster-config` at -10 vs `crossplane-resources` at 0)
  is separate from per-resource within-app wave ordering. This spec covers
  only the within-app resource view. Cross-app ordering is already visible via
  `kubectl get applications -n argocd` and is addressed by `scripts/argocd-
  apps.sh`.
- **No watch / live-refresh mode.** One-shot output only. A `watch -n5
  scripts/argocd-syncwave-view.sh <app>` invocation by the operator is the
  live-view path.
- **No changes to Terraform, Crossplane, policies, or ArgoCD manifests.**
  This spec touches only `scripts/`, `scripts/_lib/`, and `tests/unit/`.

### Considered and rejected

- **Using `argocd app get --output tree`**: requires the `argocd` binary and
  an authenticated session, neither of which is guaranteed in chainsaw or
  Pluralsight runners. Rejected in favour of pure kubectl.
- **JSON output mode**: primary consumer is a human operator; structured JSON
  adds complexity without value until a downstream consumer exists. Rejected.
- **Reading annotations from Git source**: works for `argocd/apps/*.yaml` but
  not for resources in the synced paths. Live cluster state is authoritative.

## 4. Files to change / create

| Path | What changes |
|---|---|
| `/home/user/k8-platform/scripts/_lib/k8s-helpers.sh` | **Create** (new shared library). Provides `require_kubectl`, `kubectl_or_die`, `color_ok`, `color_warn`, `color_fail` helpers sourced by the new script and by future scripts in `scripts/`. |
| `/home/user/k8-platform/scripts/argocd-syncwave-view.sh` | **Create**. Main diagnostic script per this spec. |
| `/home/user/k8-platform/tests/unit/test_argocd_syncwave_view.sh` | **Create**. Unit tests per §6. |
| `/home/user/k8-platform/scripts/README.md` | **Modify**. Add one row to the script inventory table naming `argocd-syncwave-view.sh` and its purpose. |
| `/home/user/k8-platform/AGENTS.md` | **Modify** §8 (or whichever section lists diagnostic scripts). Add one sentence naming `argocd-syncwave-view.sh` as the first-reach tool when an ArgoCD sync is stalling or completing in unexpected order. |

## 5. Implementation notes

### 5.1 Script skeleton and sourcing `_lib/k8s-helpers.sh`

```bash
#!/usr/bin/env bash
# scripts/argocd-syncwave-view.sh <app-name>
# Prints the resources managed by an ArgoCD Application, sorted by
# argocd.argoproj.io/sync-wave annotation value (numeric ascending).
#
# Exit codes: 0=success, 1=usage/prereq error, 2=app not found.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_lib/k8s-helpers.sh
. "${SCRIPT_DIR}/_lib/k8s-helpers.sh"

APP="${1:-}"
if [ -z "$APP" ]; then
  echo "Usage: $0 <argocd-app-name>" >&2
  exit 1
fi
require_kubectl   # from _lib; exits 1 with message if kubectl not on PATH
```

### 5.2 Reading the `argocd.argoproj.io/sync-wave` annotation

ArgoCD stores the live resource tree in
`.status.resources[]` on the Application object. Each element has
`kind`, `name`, `namespace`, `syncStatus`, `health.status`.
The `sync-wave` annotation lives on the resource itself, not on the
Application status entry. The fetch sequence is therefore two-step:

**Step 1** — enumerate resources from Application status:

```bash
RESOURCES=$(kubectl get application.argoproj.io "$APP" -n argocd \
  -o json 2>/dev/null) || {
    echo "ERROR: application '$APP' not found in namespace argocd" >&2
    exit 2
  }

# Extract resource list: one line per resource — "kind|name|namespace|syncStatus|healthStatus"
mapfile -t RESOURCE_LINES < <(echo "$RESOURCES" | jq -r '
  .status.resources[]?
  | [ .kind, .name, (.namespace // ""), (.status // "Unknown"),
      (.health.status // "Unknown") ]
  | join("|")
')
```

**Step 2** — for each resource, query the annotation:

```bash
get_wave() {
  local kind="$1" name="$2" ns="$3"
  local wave
  if [ -n "$ns" ]; then
    wave=$(kubectl get "$kind" "$name" -n "$ns" \
      -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/sync-wave}' \
      2>/dev/null)
  else
    wave=$(kubectl get "$kind" "$name" \
      -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/sync-wave}' \
      2>/dev/null)
  fi
  # Default wave is 0 when annotation is absent (ArgoCD default)
  echo "${wave:-0}"
}
```

The `argocd.argoproj.io/sync-wave` annotation value is a string
representation of an integer. ArgoCD treats absent annotation as wave `0`.
The script must cast to integer for numeric sort:

```bash
printf '%s\n' "${rows[@]}" | sort -t'|' -k1,1n
```

where rows are prefixed with the wave integer as column 1.

### 5.3 Output format

```
Application: crossplane-resources   sync=Synced   health=Healthy

Wave  Kind                     Name                                  Namespace          Sync       Health
----  -------                  ----                                  ---------          ----       ------
   0  CompositeResourceDef     xplatformsecrets.platform...          (cluster)          Synced     Healthy
   0  Composition              xplatformsecret-aws-secrets-manager   (cluster)          Synced     Healthy
   1  ClusterPolicy            09-platform-secret-namespace-allowed  (cluster)          Synced     Healthy
```

Color rules (applied only when stdout is a TTY — `[ -t 1 ]`):
- `Synced`/`Healthy` → green (via `color_ok` from `_lib`)
- `OutOfSync`/`Degraded`/`Missing` → red (via `color_fail`)
- `Progressing`/`Unknown`/`Suspended` → yellow (via `color_warn`)

Column widths: Wave=5, Kind=24, Name=36, Namespace=18, Sync=10, Health=10.
Truncate with `${val:0:N}` to stay within budget. Total line width ≤110
characters; safe for 120-column terminals and GitHub log display.

Output budget: ≤200 lines for an Application with ≤200 resources
(above that, print the first 200 and a `(+N more, omitted)` line). This
keeps output readable without truncation for all current Applications
(crossplane-resources has ~5 resources; management-cluster-config has ~3).

### 5.4 Failure-mode handling

- **App not found**: print `ERROR: application '<name>' not found in
  namespace argocd` to stderr, exit 2.
- **kubectl not on PATH**: `require_kubectl` prints a message and exits 1.
- **Resource fetch fails for one resource** (e.g., RBAC does not allow
  reading a particular kind): print `  WARN: could not fetch wave for
  <kind>/<name> — defaulting to wave 0` to stderr, use `0` and continue.
  Never abort the whole table on one missing annotation.
- **Empty resource list** (App exists but `.status.resources` is absent
  or empty — e.g., App is OutOfSync and has never been applied): print
  `INFO: application '<name>' has no resources in status yet — has it
  been synced?` and exit 0.
- **jq not on PATH**: print `ERROR: jq is required (not found on PATH)`
  and exit 1. Note in `require_kubectl` equivalent (`require_jq`).

### 5.5 Performance expectation

One `kubectl get application` call + one `kubectl get <kind>` call per
resource. For the three current Applications (3–6 resources each), total
wall-clock is under 3 seconds on a reachable cluster. Scripts with >20
resources should complete in under 10 seconds (acceptable for an operator
running this interactively while watching a sync).

### 5.6 Relationship to `scripts/_lib/k8s-helpers.sh`

The `_lib/` directory is created by this spec as the first shared library
under `scripts/`. It must be sourced with an absolute path derived from
`${BASH_SOURCE[0]}` (not a relative path) so the script works regardless
of the caller's working directory. Future scripts (`diag-component.sh`,
`argocd-apps.sh`) may be refactored to source helpers from `_lib/` in
follow-on work; that refactor is not in this spec.

`k8s-helpers.sh` exports (via function definitions, not `export`):
- `require_kubectl` — exits 1 if kubectl absent
- `require_jq` — exits 1 if jq absent
- `color_ok <text>` — wraps text in ANSI green if TTY, else passthrough
- `color_warn <text>` — ANSI yellow
- `color_fail <text>` — ANSI red

## 6. Tests required

Per `AGENTS.md §6.1`, unit tests are always required. Integration and
chainsaw layers apply only where feasible given this script's read-only
cluster-query nature.

| Layer | File | Assertion |
|---|---|---|
| Unit (fixture-based) | `tests/unit/test_argocd_syncwave_view.sh` | Given a canned JSON fixture mimicking `kubectl get application -o json`, the wave-extraction logic outputs rows sorted numerically by wave (wave -10 before 0 before 1). Asserts the header line contains `Wave`, `Kind`, `Name`, `Sync`, `Health`. |
| Unit (default-wave) | same file | Resource with no `argocd.argoproj.io/sync-wave` annotation defaults to wave `0`, not to empty string or error. |
| Unit (empty-resources) | same file | Application with `.status.resources` absent or empty prints the `INFO:` message and exits 0. |
| Unit (script lint) | `tests/unit/run.sh` via shellcheck | `argocd-syncwave-view.sh` and `scripts/_lib/k8s-helpers.sh` pass `shellcheck -S warning`. No new lint exceptions. |
| Unit (lib sourcing) | `tests/unit/test_argocd_syncwave_view.sh` | `scripts/_lib/k8s-helpers.sh` is sourceable in isolation without error (`bash -c '. scripts/_lib/k8s-helpers.sh'` exits 0). |

Per `AGENTS.md §6.4`, dispatch an adversarial subagent review before
drafting. Key contracts: annotation-absent defaults to wave 0; sort is
numeric not lexicographic; TTY-detection for color; RBAC-failure fail-soft;
empty-resource-list path; `_lib` path-portability.

## 7. Testing suggestions (unit / integration / e2e)

Distinct from §6's gate; these are follow-on tests as the system matures.

**Unit**

- `test_argocd_syncwave_view_color.sh` — mock TTY detection; assert ANSI
  escape codes appear for a `Degraded` resource but are absent when stdout
  is not a TTY.
- `test_argocd_syncwave_view_truncation.sh` — feed a 201-resource fixture;
  assert output contains `(+1 more, omitted)` and is ≤202 lines.
- `test_k8s_helpers_no_kubectl.sh` — shadow kubectl with a no-op returning
  1; assert `require_kubectl` writes to stderr and exits 1.

**Integration**

- `tests/integration/NN_argocd_wave_view_smoke.sh` — against the live
  management cluster: run `scripts/argocd-syncwave-view.sh crossplane-
  resources` and assert (a) exit 0, (b) output contains `ClusterPolicy`
  on a line whose wave column reads `1`, (c) all XRD lines appear at
  wave 0. Confirms the live annotation values match what the spec
  documents.
- Same test parameterized for `management-cluster-config` — asserts the
  ClusterSecretStore resource appears at wave 0 (or whatever its live
  annotation value is).

Note: `tests/integration/run.sh` has no ArgoCD-present kind cluster. Until
that infrastructure exists, integration tests run manually with `KUBECONFIG`
pointing at a live cluster where ArgoCD is deployed.

**E2E**

- Not applicable for this phase. The script is a read-only diagnostic; it
  has no side effects and no provisioning path to exercise in a chainsaw
  scenario. A chainsaw test would add cluster setup overhead for no
  additional correctness coverage beyond the integration smoke test above.
  Re-evaluate when phase-3 adds a dedicated ArgoCD chainsaw fixture that
  brings up a kind cluster with ArgoCD installed.

## 8. Documentation updates

- **`AGENTS.md`** (§8 or the diagnostic-scripts section): add a bullet
  naming `scripts/argocd-syncwave-view.sh` as the first-reach tool when
  an ArgoCD sync is stalling or ordering is unclear; point at SPEC-LA7.
- **`scripts/README.md`**: add one row for `argocd-syncwave-view.sh` in
  the script inventory table.
- **`ai/handoff.md`**: one-line mention alongside `argocd-apps.sh` and
  `diag-component.sh` in the scripts inventory.
- **`ai/testing-guidelines.md`**: if a fixture-based unit-test section
  exists, note `test_argocd_syncwave_view.sh` as a reference implementation
  for the kubectl-JSON fixture pattern.

## 9. Workflow / auto-invocation wiring

This is a **manually invoked runbook script**, not a CI step. An operator
or agent types `scripts/argocd-syncwave-view.sh <app>` at the terminal or
in a Bash tool call. No pre-commit hook, no CI workflow, no skill
auto-trigger wires to it.

Discoverability path: `AGENTS.md` names it in the diagnostic-scripts
section (per §8 above); any agent reading AGENTS.md first (per §1) will
find it before dispatching a blind `argocd app get`. If a future
`argocd-sync-watch` skill is added, its SKILL.md should reference this
script as the pre-flight ordering check in Phase 1.

## 10. Discoverability

1. **Mechanical enforcement** — `tests/unit/test_argocd_syncwave_view.sh`
   asserts the script exists at the expected path
   (`/home/user/k8-platform/scripts/argocd-syncwave-view.sh`). If a
   rename or deletion removes it, the unit test goes red in CI via
   `.github/workflows/unit-tests.yml`.
2. **Documentation pointer** — `AGENTS.md` (after §8 update) names the
   script explicitly in the diagnostic-scripts inventory. Any agent that
   reads AGENTS.md per §1 will encounter it before trying to diagnose
   an ArgoCD sync ordering problem by hand.
3. **Adversarial-review trigger** — `AGENTS.md §6.4` review checklist
   item: "When a sync ordering or wave sequencing problem is described,
   does the test plan include a `scripts/argocd-syncwave-view.sh` call
   to baseline the current ordering before making changes?" This surfaces
   the script whenever a new wave annotation is being authored.

## 11. Verification checklist

- [ ] `bash -n scripts/argocd-syncwave-view.sh` exits 0 (syntax check).
- [ ] `bash -n scripts/_lib/k8s-helpers.sh` exits 0.
- [ ] `shellcheck -S warning scripts/argocd-syncwave-view.sh` exits 0
      with no warnings.
- [ ] `shellcheck -S warning scripts/_lib/k8s-helpers.sh` exits 0.
- [ ] `tests/unit/run.sh` passes including
      `test_argocd_syncwave_view.sh`.
- [ ] Running `scripts/argocd-syncwave-view.sh` with no arguments prints
      usage to stderr and exits 1 (not 0):
      `scripts/argocd-syncwave-view.sh; echo "exit=$?"` → `exit=1`.
- [ ] Feed the fixture with resources at waves `-10`, `0`, `1`, `10`
      and assert sorted output order is `-10`, `0`, `1`, `10` (numeric,
      not lexicographic) — confirmed by the unit test for the
      default-wave and sort cases.
- [ ] The fixture with no `.status.resources` field produces the
      `INFO:` message on stdout and exits 0:
      `echo '{"status":{}}' | ...` path in the unit test.
- [ ] `grep -c 'argocd\.argoproj\.io/sync-wave' \
      scripts/argocd-syncwave-view.sh` returns ≥ 1 (annotation key
      is present in the script, not hardcoded by a different name).
- [ ] `grep -r 'argocd-syncwave-view' AGENTS.md scripts/README.md` finds
      at least one match in each file (documentation updated).
- [ ] Script produces the expected three-section output (header,
      separator, data rows) against the
      `crossplane-resources` Application fixture with wave-0 XRDs and
      wave-1 policy: the `ClusterPolicy` row sorts below both XRD rows.

## 12. Rollout notes

- **Backward-compat**: the script is new; no existing behavior changes.
  `scripts/_lib/k8s-helpers.sh` is a new file; no existing scripts
  source it, so no regressions are possible.
- **Audit-before-merge**: no existing files are modified except
  `scripts/README.md` and `AGENTS.md` (documentation-only edits). Both
  edits are additive; no existing content is removed. The PR lands green
  on the first merge.
- **Pluralsight sandbox constraints**: the script makes only read-only
  kubectl calls. No AWS API calls, no region constraint, no EC2 cost.
  Fully orthogonal to the us-east-1/us-west-2 and instance-type limits.
- **In-flight branches**: no known in-flight branches touch `scripts/_lib/`
  or `scripts/argocd-syncwave-view.sh`. Safe to merge without coordination.
  No dependency on `CLUSTERING-REVIEW.md` ordering; lands on any branch.

## 13. Estimated effort

**S** (≤1 hr).

- Authoring `k8s-helpers.sh` (five small functions): ~10 minutes.
- Authoring `argocd-syncwave-view.sh` (~80 lines of bash): ~20 minutes.
- Authoring `test_argocd_syncwave_view.sh` (three JSON fixtures, five
  assertions): ~20 minutes.
- Documentation edits (AGENTS.md, README, handoff): ~5 minutes.
- Smoke-test (shellcheck + `tests/unit/run.sh`): ~5 minutes.

Total: ~60 minutes. No Terraform, no cluster provisioning, no ArgoCD
manifest changes. Effort is dominated by the fixture JSON for unit tests.
