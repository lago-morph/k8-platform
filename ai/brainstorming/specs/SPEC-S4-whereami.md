# SPEC-S4 — `scripts/whereami.sh --json` session-start probe + precondition gate

## 1. Summary

Add `scripts/whereami.sh`, a single read-only bash script that prints the
seven pieces of environment state every agent session needs in the first 30
seconds: AWS account ID, region, EKS cluster name, availability zone, current
kubectl context, ArgoCD URL, and Crossplane version. With no flags the output
is human-readable; with `--json` it emits a compact JSON object that e2e tests
can consume as a precondition gate — asserting account/region/cluster match
`terraform.tfvars` before running against the wrong sandbox. The script is the
first consumer of `scripts/_lib/aws-cli-helpers.sh`, the shared helper module
S4 introduces and every later Tier S/A/C script reuses. Sequenced as prereq
PR-S.0 alongside `aws-cli-helpers.sh` before S5 (`phase-status.sh`), per the
"Cross-cutting infrastructure" table in `larger-list-preferences.md` (row 3).

## 2. Retro pain killed

- **Five manual invocations at every session start (AGENTS.md §8.1 lines
  508–511).** The three prescribed session-start commands spawn 5+ separate
  aws/kubectl calls, each with a cold SDK round-trip. Multiple retrospectives
  record "verified environment" as a multi-minute manual sequence. `whereami.sh`
  collapses this to one call.
- **`scripts/aws-creds-check.sh` does not surface kubectl context or ArgoCD URL.**
  It confirms credentials and lists EKS clusters but does not confirm the active
  kubectl context matches the discovered cluster, does not surface the ArgoCD
  URL, and does not report the Crossplane version. Agents have proceeded with a
  context pointing at a prior session's cluster, discovered the mismatch only
  during a failing `kubectl apply`, and wasted a debug loop.
- **E2e tests running against the wrong sandbox (A2→A1-001).** Without a
  machine-readable probe, e2e scripts cannot assert account/region/cluster
  match `terraform.tfvars` before running.
- **N subagents re-probing STS/EKS (A5→A1-001).** A5: "Avoids N subagents
  hammering STS/EKS describe at session start." `whereami.sh --json >
  /tmp/session.env` provides a shared cache subagents can source.
- **Per-script preambles re-echoing account/region in every diag tool (A6→A1-001).**
  A6: "Single source; preamble noise vanishes." Once `aws-cli-helpers.sh` lands,
  per-script preambles collapse to one-liners that source the helper.

## 3. Out of scope

- **Automatic session-start invocation wiring (AGENTS.md §9, hooks).** The
  `session-start-hook` skill owns hooking `whereami.sh` into the Claude Code
  `SessionStart` event. This spec only delivers the script itself.
- **Writing to `/tmp/session.env` by default.** The A5 comment proposes caching
  to `/tmp/session.env`. That behavior is opt-in via a `--cache` flag (see §5);
  the default exits cleanly so the script is safe as a one-shot query.
- **`scripts/phase-status.sh` (S5).** S5 is the next prereq PR; it will source
  `aws-cli-helpers.sh` as introduced here. S5 is out of scope for this spec.
- **Retiring per-script preambles in `scripts/*.sh`.** Refactoring existing
  scripts to source `aws-cli-helpers.sh` is a follow-on chore PR after S4 and
  S5 land; doing it here risks breaking existing behavior without test coverage.
- **ArgoCD authentication or health checks.** The URL is derived from a known
  service naming convention (see §5); `whereami.sh` does not authenticate to
  ArgoCD or assert its health. That is `scripts/argocd-apps.sh`'s domain.

**Considered and rejected:**

- **Extending `aws-creds-check.sh` instead of creating a new script.**
  `aws-creds-check.sh` exits non-zero on any missing prerequisite; `whereami.sh`
  is a probe that warns on soft mismatches and exits 0 unless credentials are
  fully absent. Merging the semantics requires flag proliferation that hurts
  discoverability.
- **POSIX `/bin/sh`.** The helper uses bash arrays; EKS environments run
  bash ≥4. Portability vs. clarity — clarity wins given the repo's existing
  `#!/usr/bin/env bash` convention.
- **Single-binary wrapper (Python/Go).** `scripts/` uses bash throughout;
  a compiled binary adds a build dependency and is not editable in-session.
  7 fields fit comfortably in ~100 lines of bash.

## 4. Files to change / create

**Create:**

| Path | Purpose |
|------|---------|
| `/home/user/k8-platform/scripts/whereami.sh` | Main probe script, human and JSON output modes |
| `/home/user/k8-platform/scripts/_lib/aws-cli-helpers.sh` | Shared helper functions sourced by whereami.sh and future scripts |
| `/home/user/k8-platform/tests/unit/test_whereami.sh` | Unit tests covering both output modes, field presence, and --json schema |

**Modify:**

| Path | What changes |
|------|-------------|
| `/home/user/k8-platform/tests/unit/run.sh` | Add `run_suite tests/unit/test_whereami.sh` |
| `/home/user/k8-platform/AGENTS.md` | §8.1: add pointer to `whereami.sh` as the canonical session-start probe |
| `/home/user/k8-platform/ai/testing-guidelines.md` | Add row for `test_whereami.sh` in the unit-test inventory |
| `/home/user/k8-platform/scripts/README.md` | Add `whereami.sh` entry with one-line description |

## 5. Implementation notes

### `scripts/_lib/aws-cli-helpers.sh` — the shared module

This file is sourced (`. scripts/_lib/aws-cli-helpers.sh`), never executed
directly. It exports these functions:

```bash
# Returns the caller's 12-digit account ID or the string "UNKNOWN" on failure.
aws_account_id()   { aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "UNKNOWN"; }

# Returns the resolved AWS region: $AWS_REGION, then $AWS_DEFAULT_REGION,
# then the EC2 IMDSv2 region, then "us-east-1" as a last-resort fallback.
aws_region()       { ... }

# Returns the first EKS cluster name in the resolved region, or empty string.
aws_eks_cluster()  { aws eks list-clusters --region "$(aws_region)" --output text \
                       --query 'clusters[0]' 2>/dev/null; }

# Returns the AZ of the first EKS node, or empty string.
aws_eks_zone()     { ... }  # uses 'kubectl get nodes -o jsonpath' if kubeconfig valid

# Returns the active kubectl context name.
k8s_context()      { kubectl config current-context 2>/dev/null || echo "(none)"; }

# Returns the ArgoCD server URL by discovering the argocd-server service.
# Falls back to the LoadBalancer hostname if no Ingress is found.
argocd_url()       { ... }

# Returns the Crossplane core version from the crossplane-system deployment.
crossplane_version() { kubectl get deployment crossplane -n crossplane-system \
                         -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null \
                         | sed 's/.*://'; }
```

Each function is safe to call individually and silently returns a sentinel
value on failure (empty string or "UNKNOWN") so callers can decide how to
handle partial availability. Functions never exit the calling script.

### `scripts/whereami.sh` — the main script

```bash
#!/usr/bin/env bash
# One-shot session-start probe: account ID, region, EKS name, zone,
# kubectl ctx, ArgoCD URL, Crossplane version.
# Usage:
#   scripts/whereami.sh          # human-readable output
#   scripts/whereami.sh --json   # JSON object, suitable for jq / precondition gates
#   scripts/whereami.sh --cache  # JSON to stdout AND writes /tmp/session.env
# Exit 0 on success; exit 1 only if AWS credentials are completely absent.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_lib/aws-cli-helpers.sh
. "$SCRIPT_DIR/_lib/aws-cli-helpers.sh"
```

**Field collection order.** The script collects all seven fields before
printing, so a slow STS call does not interleave with partial output:

```
ACCOUNT=$(aws_account_id)
REGION=$(aws_region)
CLUSTER=$(aws_eks_cluster)
ZONE=$(aws_eks_zone)
CTX=$(k8s_context)
ARGOCD=$(argocd_url)
XPVERSION=$(crossplane_version)
```

**Human mode (default).** Produces aligned output matching the style of the
existing `scripts/k8s-status.sh` section headers:

```
── whereami ────────────────────────────────────────────────────────
  account       123456789012
  region        us-east-1
  eks-cluster   k8-platform-dev
  zone          us-east-1a
  kubectl-ctx   arn:aws:eks:us-east-1:...:cluster/k8-platform-dev
  argocd-url    https://argocd.k8-platform-dev.<zone>.realhandsonlabs.net
  crossplane    v0.15.1
```

Sentinel values ("UNKNOWN", empty string) trigger a `WARN:` annotation on
the same line. The script exits 0 even with warnings; it exits 1 only if
`ACCOUNT == "UNKNOWN"` (credentials absent).

**JSON mode (`--json`).** Emits a single-line JSON object with consistent
field names for scripted consumers:

```json
{"account":"123456789012","region":"us-east-1","eksCluster":"k8-platform-dev","zone":"us-east-1a","kubectlCtx":"arn:aws:eks:us-east-1:...:cluster/k8-platform-dev","argoCdUrl":"https://...","crossplaneVersion":"v0.15.1"}
```

Empty/UNKNOWN fields are included as empty strings so consumers can assert
presence without null-guard logic.

**Cache mode (`--cache`).** Writes the JSON to stdout AND to `/tmp/session.env`
as `KEY=value` shell variable pairs (for `source`-ability by subagents). The
keys are uppercased: `ACCOUNT`, `REGION`, `EKS_CLUSTER`, `ZONE`,
`KUBECTL_CTX`, `ARGOCD_URL`, `CROSSPLANE_VERSION`.

**E2e precondition gate pattern.** The intended use in `tests/e2e/` harnesses:

```bash
ENV=$(scripts/whereami.sh --json)
EXPECTED_ACCOUNT=$(jq -r '.account' terraform/terraform.tfvars.json)
ACTUAL_ACCOUNT=$(echo "$ENV" | jq -r '.account')
[ "$ACTUAL_ACCOUNT" = "$EXPECTED_ACCOUNT" ] || {
  echo "FAIL: wrong account. Expected $EXPECTED_ACCOUNT, got $ACTUAL_ACCOUNT" >&2
  exit 1
}
```

**Performance target.** Cold run must complete in ≤15 s (STS ~300 ms +
`kubectl get nodes` ~1 s; warm session is ~3–5 s). Implemented with a
`timeout 15` wrapper around the collection block; on timeout the script
exits 1 with a clear message.

**No account-derived values are hardcoded.** All identifiers are read at
runtime per AGENTS.md §8.1.

### `scripts/_lib/` directory conventions

`aws-cli-helpers.sh` is the first file in the new `scripts/_lib/` directory,
the bash-library peer of `tests/chainsaw/_lib/` (SPEC-A4). Convention:

- No shebang line; sourced, never executed directly.
- One-paragraph `# PURPOSE:` comment block at the top.
- Names prefixed: `aws_*` for AWS helpers; `k8s_*` reserved for
  `scripts/_lib/k8s-helpers.sh` (introduced by S7).
- Every function is `set -eo pipefail`-safe (no bare command substitution
  without a fallback sentinel).

## 6. Tests required

Per AGENTS.md §6.1 (test-layer policy):

| Layer | File | Assertion |
|---|---|---|
| Unit | `/home/user/k8-platform/tests/unit/test_whereami.sh` | `--json` flag produces valid JSON (via `jq empty`). All seven field names are present. No field is the string `null`. |
| Unit | same | Human mode produces a line matching `^\s*account\s` and a line matching `^\s*region\s`. Proves field labels are stable. |
| Unit | same | With mock `aws` and `kubectl` binaries returning fixed values (via `PATH` override in a `tests/unit/fixtures/whereami/` shim dir), `--json` output matches an expected JSON fixture. This is the self-test that proves the helper functions compose correctly. |
| Unit | same | `--cache` mode writes `/tmp/session.env` and the file contains `ACCOUNT=` and `EKS_CLUSTER=` lines. |
| Unit | same | When the mock `aws sts get-caller-identity` exits 1, the script exits 1 (credential-absent sentinel). All other mock-failure modes (kubectl absent, EKS cluster absent) exit 0 with WARN annotations. |

Per §6.4, before authoring the test file dispatch a subagent with: the two
new files and four modified files as shipped facts, the precondition-gate
usage pattern, and the explicit non-goal "we are not testing AWS API behavior,
only the script's composition logic".

## 7. Testing suggestions (unit / integration / e2e)

### Unit

Tests in this layer use fixture shims (a `tests/unit/fixtures/whereami/`
directory containing stub `aws` and `kubectl` scripts on PATH) — all run in
<5 s with no AWS credentials required.

1. **`test_whereami_json_schema`** — assert `--json` output passes `jq
   'has("account") and has("eksCluster") and has("crossplaneVersion")'`.
2. **`test_whereami_human_fields`** — grep human output for each of the 7
   field labels, fail if any is absent.
3. **`test_whereami_cache_file`** — run `--cache`, assert `/tmp/session.env`
   is created and is source-able without error (`bash -c '. /tmp/session.env'`).
4. **`test_whereami_no_creds_exits_1`** — shim `aws` to exit 1; assert
   `whereami.sh` exits 1 and stderr contains "credentials".
5. **`test_whereami_partial_availability`** — shim `kubectl` to exit 1; assert
   `whereami.sh` exits 0 and `--json` output still has all 7 keys (empty
   strings for kubectl-derived fields).

### Integration

Tests run against a live AWS session (not necessarily a live cluster). Requires
`AWS_REGION` and valid credentials.

1. **`tests/integration/40_whereami_live.sh`** — run `scripts/whereami.sh
   --json`; assert `jq -e '.account | test("^[0-9]{12}$")'` passes.
2. **`tests/integration/41_whereami_ctx_matches_cluster.sh`** — assert
   `kubectlCtx` contains the string from `aws_eks_cluster()`. Catches the
   silent context-mismatch failure mode.
3. **`tests/integration/42_whereami_helpers_lib.sh`** — source
   `scripts/_lib/aws-cli-helpers.sh` directly; call `aws_account_id` and
   `aws_region`; assert each returns non-empty, non-UNKNOWN.

### E2e

Tests run against a deployed phase-0+ cluster.

1. **`tests/e2e/00_precondition/run.sh`** — call `scripts/whereami.sh --json`;
   compare `account` and `region` to `terraform/terraform.tfvars.json`;
   fail clearly if they diverge. Becomes the mandatory first step of every
   e2e harness (prevents the "wrong sandbox" class, A2→A1-001).
2. **`tests/e2e/00_precondition/run.sh` (extended)** — assert
   `crossplaneVersion` matches the pinned version in
   `crossplane/crossplane-values.yaml`.

Chainsaw is not applicable: `whereami.sh` is a read-only probe, not an
XRD/Composition. This omission is deliberate, not an oversight.

## 8. Documentation updates

- **`/home/user/k8-platform/AGENTS.md` §8.1** — replace the three-item session-
  start list (lines 508–511) with: *"Run `scripts/whereami.sh` as the first
  command of every session; `--json` for machine-readable output. Replaces
  manual `aws sts get-caller-identity` / `aws eks list-clusters` and surfaces
  kubectl context, ArgoCD URL, and Crossplane version in one call (SPEC-S4)."*
- **`/home/user/k8-platform/ai/testing-guidelines.md`** — add unit-test row:
  `test_whereami.sh | JSON schema + credential-absent exit. Fixtures in
  tests/unit/fixtures/whereami/.`
- **`/home/user/k8-platform/scripts/README.md`** — add `whereami.sh` entry:
  "Session-start probe: account, region, EKS, zone, kubectl ctx, ArgoCD URL,
  Crossplane version. Use `--json` as an e2e precondition gate."

## 9. Workflow / auto-invocation wiring

`whereami.sh` is designed to be invoked at session start. The wiring happens
in two places:

1. **Manual invocation (immediate):** AGENTS.md §8.1 (updated per §8 above)
   instructs agents to run it as the first command. This is the primary
   delivery mechanism.
2. **Session-start hook (follow-on):** The `session-start-hook` skill can wire
   `scripts/whereami.sh --cache` into the Claude Code `SessionStart` hook,
   writing `/tmp/session.env` before the first agent prompt. That wiring is
   out of scope (see §3); the `--cache` flag is implemented here so it is
   trivial to add.

`tests/unit/run.sh` runs `test_whereami.sh` on every push via
`.github/workflows/unit-tests.yml` — the existing `run_suite` discovery covers
it once the entry is added per §4. The e2e precondition script
(`tests/e2e/00_precondition/run.sh`) is created by this spec; wiring it into
a future `e2e.yml` workflow costs one line when that workflow lands.

## 10. Discoverability

1. **Mechanical enforcement** — `test_whereami.sh` runs on every push; a
   drifted `--json` schema (renamed or dropped field) fails CI immediately.
   The e2e precondition gate (`tests/e2e/00_precondition/run.sh`) fails any
   e2e run against the wrong sandbox before any destructive call.
2. **Documentation pointer** — AGENTS.md §8.1 updated to name `whereami.sh`
   with `(SPEC-S4)`. `scripts/README.md` lists it at the top of the table
   (ordered by importance, not alphabet).
3. **Adversarial-review trigger** — add to `ai/testing-guidelines.md` §6.4
   checklist: *"For any new e2e or integration test, confirm the first step
   invokes `scripts/whereami.sh --json` as a precondition gate (SPEC-S4 §5)."*

## 11. Verification checklist

- [ ] `bash /home/user/k8-platform/scripts/whereami.sh --help` exits 0 and
  prints the Usage block.
- [ ] `bash /home/user/k8-platform/scripts/whereami.sh --json | jq 'keys | length'`
  returns exactly 7.
- [ ] `bash /home/user/k8-platform/scripts/whereami.sh --json | jq -e 'to_entries | map(.value != null) | all'`
  exits 0 (no null values; empty strings are acceptable, nulls are not).
- [ ] `bash /home/user/k8-platform/tests/unit/test_whereami.sh` exits 0 with
  one `PASS` line per test case (at least 5 cases).
- [ ] `bash /home/user/k8-platform/tests/unit/run.sh` includes `test_whereami`
  and exits 0.
- [ ] With `PATH` prepended by `tests/unit/fixtures/whereami/` (shim dir),
  `scripts/whereami.sh --json` matches `tests/unit/fixtures/whereami/expected.json`
  field-for-field.
- [ ] Shim `aws` to exit 1; confirm `scripts/whereami.sh` exits 1 and stderr
  line contains "credentials".
- [ ] Remove shim; run `scripts/whereami.sh --cache`; confirm
  `/tmp/session.env` is created; run `bash -c '. /tmp/session.env && echo $ACCOUNT'`
  and confirm it prints a non-empty value.
- [ ] `grep -n "whereami" /home/user/k8-platform/AGENTS.md` shows ≥1 hit in
  the §8.1 region (lines ~505–515).
- [ ] `bash /home/user/k8-platform/scripts/_lib/aws-cli-helpers.sh` exits
  non-zero with a clear "this file must be sourced" message (preventing
  accidental direct execution).

## 12. Rollout notes

- **Backward compatible.** No existing file is modified in a behavior-changing
  way. `scripts/aws-creds-check.sh` continues to work unchanged; this spec
  does not alter it.
- **Audit-before-merge.** The script must contain no hardcoded account IDs,
  region strings, or cluster names. Run `tests/unit/test_no_account_id_hardcoded.sh
  --self-test` (SPEC-B5) against the new files before merging to catch any
  accidental literal that slipped in during authoring.
- **Pluralsight sandbox constraints** (us-east-1/us-west-2 only, t-class
  instances, ≤9 EC2, no Bedrock/Marketplace) — orthogonal to this spec. The
  script is a read-only probe; it consumes no AWS quota beyond one STS call
  and one EKS list-clusters call.
- **Branch sequencing.** Per `larger-list-preferences.md` recommended
  implementation order, S4 lands on `feat/whereami-session-probe` as the
  first commit of Session 1 work. S5 (`phase-status.sh`) branches from S4's
  merged commit and sources `aws-cli-helpers.sh`. Do not attempt to land
  both in the same PR — S5 is meaningfully larger and the helper module
  needs its own CI green before S5 depends on it.
- **Coordination with in-flight branches.** No known in-flight branch touches
  `scripts/_lib/` (the directory does not yet exist). If the B5 account-ID
  lint PR is in flight simultaneously, add `# noqa: account-id - fixture only`
  markers to any `tests/unit/fixtures/whereami/` fixture that uses a synthetic
  12-digit ID.

## 13. Estimated effort

**S** (≤1 hr).

~20 min `aws-cli-helpers.sh` (7 functions); ~20 min `whereami.sh` (~100
lines, flag dispatch + two output modes + `--cache`); ~20 min
`test_whereami.sh` (5 cases + fixture shim dir); ~10 min doc edits
(AGENTS.md §8.1, testing-guidelines.md, README.md, run.sh line); ~10 min
§11 smoke run. Total ≈80 min. No AWS spend. Only risk: fixture PATH-override
wiring in the unit test — budget +15 min if `run.sh` lacks a needed helper.
