#!/usr/bin/env bash
# Unit test for the chainsaw ASM cleanup helpers
# (tests/chainsaw/_lib/asm-cleanup.sh) and their contract with the
# PlatformSecret Composition.
#
# Defends OI-2026-05-28-1 "ASM cleanup-trap gap": the Composition names ASM
# secrets `k8-platform/<XR-uid>`, but the old cleanup filtered AWS by
# `${ASM_RUN_PREFIX}/` (= `k8-platform-chainsaw-<id>/`) which can never
# match, so every chainsaw run leaked its secrets. The fix enumerates the
# real names from the Secret MRs in the live cluster. These tests drive the
# lib functions BEHAVIORALLY with stubbed kubectl/aws (not grep over source),
# so they survive a correct re-implementation and fail for the right reason.
#
# Pure-local: no real cluster, no real AWS account. Runs in
# tests/unit/run.sh on every push.

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root
REPO_ROOT="$(pwd)"

# shellcheck disable=SC1091
. tests/lib/assert.sh

LIB="tests/chainsaw/_lib/asm-cleanup.sh"
COMP="crossplane/compositions/platform-secret.yaml"
GOLDEN="crossplane/xrds/platform-secret/render-fixtures/expected.yaml"
RUNSH="tests/chainsaw/run.sh"

if [ ! -f "$LIB" ]; then
  _fail "lib_present" "$LIB missing"
  assert_summary; exit 1
fi
_pass "lib_present"

# ---------------------------------------------------------------------------
# Part A — static / golden contracts (real PATH; need yq for the goldens)
# ---------------------------------------------------------------------------

# A1 (cheap fast-fail): the Composition still derives the ASM secret name with
# the `k8-platform/` prefix. Catches an accidental prefix change at the source.
if grep -qE 'fmt:\s*"k8-platform/%s"' "$COMP"; then
  _pass "composition_asm_name_prefix_fmt"
else
  _fail "composition_asm_name_prefix_fmt" "expected fmt: \"k8-platform/%s\" in $COMP"
fi

# A2 (golden, the real guard for sub-questions a/f): in the committed render
# golden the rendered ASM Secret's spec.forProvider.name starts with
# `k8-platform/`. We extract by text rather than structured yq because the
# render golden packs the ExternalSecret + Secret into a single YAML document
# (no `---` between them), so a `yq select(.kind==...)` is shadowed by the
# duplicate top-level keys. Text extraction asserts the rendered output and is
# robust to that quirk.
if [ -f "$GOLDEN" ]; then
  asm_name="$(grep -oE 'name: k8-platform/[0-9a-f-]+' "$GOLDEN" | head -1 | sed 's/^name: //')"
  case "$asm_name" in
    k8-platform/*) _pass "golden_asm_name_has_k8platform_prefix (${asm_name})" ;;
    *) _fail "golden_asm_name_has_k8platform_prefix" "golden asm-secret name '${asm_name:-<none>}' lacks k8-platform/ prefix" ;;
  esac

  # A3: the ESO ExternalSecret reads the SAME ASM key the asm-secret writes —
  # both must share the k8-platform/ prefix and the SAME uid, or ESO reads a
  # key that was never written. (An invariant neither plan nor prior tests
  # covered.)
  eso_key="$(grep -oE 'key: k8-platform/[0-9a-f-]+' "$GOLDEN" | head -1 | sed 's/^key: //')"
  case "$eso_key" in
    k8-platform/*) _pass "golden_eso_key_has_k8platform_prefix (${eso_key})" ;;
    *) _fail "golden_eso_key_has_k8platform_prefix" "ESO key '${eso_key:-<none>}' lacks k8-platform/ prefix" ;;
  esac
  assert_eq "golden_asm_name_equals_eso_key" "$asm_name" "$eso_key"
else
  echo "  WARNING: render golden absent — skipping golden prefix checks"
fi

# A4 (sub-question g, order guard): the cleanup enumerate/sweep MUST run BEFORE
# `kind delete cluster` (the cluster has to be alive to list MRs). A line-order
# check survives style rewrites as long as both calls exist.
# Anchor to start-of-line (optional indent) so the header-comment mentions of
# these commands don't match — only the real invocations.
sweep_line="$(grep -nE '^[[:space:]]*asm_cleanup_run' "$RUNSH" | head -1 | cut -d: -f1)"
kinddel_line="$(grep -nE '^[[:space:]]*kind delete cluster' "$RUNSH" | head -1 | cut -d: -f1)"
if [ -n "$sweep_line" ] && [ -n "$kinddel_line" ] && [ "$sweep_line" -lt "$kinddel_line" ]; then
  _pass "sweep_runs_before_kind_delete (sweep@${sweep_line} < kind-delete@${kinddel_line})"
else
  _fail "sweep_runs_before_kind_delete" "asm_cleanup_run (line ${sweep_line:-none}) must precede kind delete (line ${kinddel_line:-none})"
fi

# A5 (wiring guard — repo has a known orphan-test failure mode): this test is
# registered in run.sh and the workflow (per-step or catch-all both ok).
grep -q 'test_chainsaw_asm_cleanup' tests/unit/run.sh \
  && _pass "wired_into_run_sh" \
  || _fail "wired_into_run_sh" "add this test to tests/unit/run.sh"
if grep -q 'test_chainsaw_asm_cleanup' .github/workflows/unit-tests.yml \
   || grep -q 'run.sh' .github/workflows/unit-tests.yml; then
  _pass "wired_into_unit_tests_yml"
else
  _fail "wired_into_unit_tests_yml" "enumerate this test or rely on the run.sh catch-all in unit-tests.yml"
fi

# ---------------------------------------------------------------------------
# Part B — behavioral: drive the lib functions with stubbed kubectl/aws.
# ---------------------------------------------------------------------------
# shellcheck disable=SC1090
. "$LIB"

MOCK_DIR="$(mktemp -d -t asmcleanup-mock-XXXXXX)"
trap 'rm -rf "$MOCK_DIR"' EXIT

cat > "$MOCK_DIR/kubectl" <<'SHIM'
#!/usr/bin/env bash
set -u
echo "kubectl $*" >> "${MOCK_KUBECTL_LOG:-/dev/null}"
# The cleanup must NEVER enumerate ExternalSecrets (ESO owns their lifecycle).
case "$*" in
  *externalsecret*|*external-secrets.io*) echo "STUB-FAIL: cleanup queried ExternalSecrets" >&2; exit 7 ;;
esac
if [ "${MOCK_KUBECTL_FAIL:-0}" = "1" ]; then
  echo "Unable to connect to the server: connection refused" >&2
  exit 1
fi
case "$*" in
  *get*secrets.secretsmanager.aws.m.upbound.io*) printf '%s' "${MOCK_ASM_NAMES:-}" ;;
  *) : ;;
esac
SHIM
chmod +x "$MOCK_DIR/kubectl"

cat > "$MOCK_DIR/aws" <<'SHIM'
#!/usr/bin/env bash
set -u
echo "aws $*" >> "${MOCK_AWS_LOG:-/dev/null}"
# Simulate a ResourceNotFound for one specific name (idempotency test).
if [ -n "${MOCK_AWS_FAIL_NAME:-}" ]; then
  case " $* " in *" ${MOCK_AWS_FAIL_NAME} "*) echo "ResourceNotFoundException" >&2; exit 254 ;; esac
fi
exit 0
SHIM
chmod +x "$MOCK_DIR/aws"

export PATH="$MOCK_DIR:$PATH"

# B1 (sub-questions 1+2): enumerate returns exactly the ASM names, never ESO.
# Two reconciled MRs (the kubectl stub exits 7 if asked about ESO).
out="$(MOCK_ASM_NAMES=$'k8-platform/uid-aaa\nk8-platform/uid-bbb\n' asm_cleanup_targets)"
assert_eq "targets_enumerates_asm_names" $'k8-platform/uid-aaa\nk8-platform/uid-bbb' "$out"

# B2 (sub-question e): an MR with an unset name (blank line) is dropped — never
# yields an empty token that could become `--secret-id ''`.
out="$(MOCK_ASM_NAMES=$'k8-platform/uid-aaa\n\nk8-platform/uid-bbb\n' asm_cleanup_targets)"
assert_eq "targets_drops_empty_unreconciled_name" $'k8-platform/uid-aaa\nk8-platform/uid-bbb' "$out"

# B3 (fail-visible): cluster unreachable → enumerate returns kubectl's non-zero
# rc (so the caller can WARN), not a silent empty success.
MOCK_KUBECTL_FAIL=1 asm_cleanup_targets >/dev/null 2>&1; b3rc=$?
assert_eq "targets_propagates_cluster_unreachable_rc" "1" "$b3rc"

# B4 (sub-question d): delete uses --force-delete-without-recovery and the exact
# secret id; never list-secrets.
awslog="$MOCK_DIR/aws.b4"; : > "$awslog"
MOCK_AWS_LOG="$awslog" asm_delete_one "k8-platform/uid-aaa" >/dev/null 2>&1
log="$(cat "$awslog")"
assert_contains "delete_uses_force_delete_flag" "--force-delete-without-recovery" "$log"
assert_contains "delete_targets_exact_id" "--secret-id k8-platform/uid-aaa" "$log"

# B5 (footgun guard): delete refuses an empty id — no aws call at all.
awslog="$MOCK_DIR/aws.b5"; : > "$awslog"
MOCK_AWS_LOG="$awslog" asm_delete_one "" >/dev/null 2>&1
assert_eq "delete_refuses_empty_id" "" "$(cat "$awslog")"

# B6 (sub-questions 9 + behavioral sweep): run the full sweep — deletes come
# from MR enumeration, exactly one delete per non-empty name, and NEVER a
# list-secrets call (the dead prefix-filter path is gone).
awslog="$MOCK_DIR/aws.b6"; kubelog="$MOCK_DIR/kube.b6"; : > "$awslog"; : > "$kubelog"
MOCK_ASM_NAMES=$'k8-platform/uid-aaa\nk8-platform/uid-bbb\n' \
  MOCK_AWS_LOG="$awslog" MOCK_KUBECTL_LOG="$kubelog" \
  asm_cleanup_run >/dev/null 2>&1
ndel="$(grep -c 'delete-secret' "$awslog" || true)"
assert_eq "sweep_one_delete_per_name" "2" "$ndel"
if grep -q 'list-secrets' "$awslog"; then
  _fail "sweep_no_list_secrets_dependency" "cleanup must not call list-secrets; got: $(cat "$awslog")"
else
  _pass "sweep_no_list_secrets_dependency"
fi
assert_contains "sweep_queries_secretsmanager_mrs" "secrets.secretsmanager.aws.m.upbound.io" "$(cat "$kubelog")"

# B7 (idempotency, sub-question 10): a ResourceNotFound on one secret is
# non-fatal — the sweep continues and still deletes the other.
awslog="$MOCK_DIR/aws.b7"; : > "$awslog"
MOCK_ASM_NAMES=$'k8-platform/uid-aaa\nk8-platform/uid-bbb\n' \
  MOCK_AWS_FAIL_NAME="k8-platform/uid-aaa" MOCK_AWS_LOG="$awslog" \
  asm_cleanup_run >/dev/null 2>&1
rc=$?
assert_eq "sweep_resourcenotfound_non_fatal" "0" "$rc"
assert_eq "sweep_continues_after_failure" "2" "$(grep -c 'delete-secret' "$awslog" || true)"

# B8 (sub-question 6, fail-visible): cluster gone → sweep WARNs loudly to
# stderr and is non-fatal (does NOT print the indistinguishable clean-run msg).
err="$(MOCK_KUBECTL_FAIL=1 asm_cleanup_run 2>&1 >/dev/null)"
assert_contains "sweep_warns_when_cluster_unreachable" "may leak" "$err"

assert_summary
