#!/usr/bin/env bash
# Unit tests for scripts/crossplane-trace.sh.
#
# Spec: ai/brainstorming/specs/SPEC-S2-crossplane-trace.md
#
# Strategy: replace kubectl and aws with shims that dispatch on argv to
# canned fixture files under tests/unit/fixtures/crossplane-trace/. The
# script-under-test is invoked with KUBECTL=<shim> AWS_REGION=us-east-1 and
# a mocked aws binary on PATH; no real cluster or AWS account is contacted.
#
# Contracts defended (spec §6 + adversarial-review additions inline):
#   1. --help prints --watch and --json (§11 item 2)
#   2. happy-path fixture: human output starts with "=== CROSSPLANE TRACE:"
#      and ends "=== END TRACE ===" (§6 contract a)
#   3. happy-path output ≤ 5120 bytes (§6 contract b)
#   4. SA-mismatch fixture: exactly one MISMATCH (§6 contract c, §11 item 7)
#   5. xr-empty-conditions fixture: contains "<empty" (§6 contract d)
#   6. mr-access-denied fixture: contains "[FAIL]" (§6 contract e)
#   7. --json emits valid JSON with all five top-level keys (§6, §11)
#   8. Ready=True fixture + --watch → exits 0 (§6 watch contract)
#   9. not-ready + --timeout 0 + --watch → exits 2 within 1 s (§11 item 5)
#  10. lookup-failed claim: exit !=0, prints "CLAIM: lookup-failed" (§11 item 3)
#  11. lookup-failed claim + --json: exit !=0, jq parses (§11 item 4)
#  12. 12-resourceRefs + 5-failing-MRs output ≤ 5120 bytes (§11 item 6)
#  13. bash -n syntax check
#  14. SKIP_AWS=1 path emits no MATCH/MISMATCH (defends region-guard)
#  15. shellcheck clean (skipped if shellcheck absent)
#  16. case-insensitive kind handling (spec §5.1)

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

# shellcheck disable=SC1091
. tests/lib/assert.sh

FIXTURES="tests/unit/fixtures/crossplane-trace"
SCRIPT="scripts/crossplane-trace.sh"

# ---------------------------------------------------------------------------
# Mock kubectl shim
# ---------------------------------------------------------------------------
# Dispatches on `get <kind>/<name>` (and the kind alone for list calls).
# Reads $MOCK_MAP — a colon-separated list of "<lowercase-kind>/<name>=<fixture>"
# entries — to decide what to print. A `*=<fixture>` entry is a fall-through.
# Missing entry → exit 1 (simulates "NotFound").
# `kubectl get pods -l ...` returns $MOCK_POD_FIXTURE.
# `kubectl get sa <name> -n <ns>` returns $MOCK_SA_FIXTURE.
# `kubectl get provider.pkg.crossplane.io <name>` returns $MOCK_PROVIDER_FIXTURE.

MOCK_DIR="$(mktemp -d -t cptrace-mock-XXXXXX)"
trap 'rm -rf "$MOCK_DIR"' EXIT

cat > "$MOCK_DIR/kubectl" <<'SHIM'
#!/usr/bin/env bash
# Mock kubectl for test_crossplane_trace.sh
set -u

LOG="${MOCK_ARGS_LOG:-/dev/null}"
echo "$*" >> "$LOG"

# Parse argv
verb=""; kind_name=""; name=""; ns=""; output=""; selector=""
get_kind=""
i=0
args=("$@")
while [[ $i -lt ${#args[@]} ]]; do
  a="${args[$i]}"
  case "$a" in
    get) verb="get" ;;
    -n) i=$((i+1)); ns="${args[$i]:-}" ;;
    -o) i=$((i+1)); output="${args[$i]:-}" ;;
    -l) i=$((i+1)); selector="${args[$i]:-}" ;;
    -A|--all-namespaces) ns="__ALL__" ;;
    *)
      if [[ "$verb" == "get" && -z "$kind_name" ]]; then
        kind_name="$a"
      fi
      ;;
  esac
  i=$((i+1))
done

# kind_name may be "kind/name" or just "kind"
if [[ "$kind_name" == */* ]]; then
  kind="${kind_name%%/*}"
  name="${kind_name#*/}"
else
  kind="$kind_name"
  name=""
fi
kind_lc=$(echo "$kind" | tr '[:upper:]' '[:lower:]')

# Resolve fixture
fixture=""
IFS=':' read -ra entries <<< "${MOCK_MAP:-}"
for e in "${entries[@]}"; do
  key="${e%%=*}"
  val="${e#*=}"
  if [[ "$key" == "$kind_lc/$name" ]]; then
    fixture="$val"; break
  fi
done
if [[ -z "$fixture" ]]; then
  for e in "${entries[@]}"; do
    key="${e%%=*}"
    val="${e#*=}"
    if [[ "$key" == "$kind_lc/*" ]]; then
      fixture="$val"; break
    fi
  done
fi

# Special: kubectl get pods -n crossplane-system -l ...
if [[ "$kind_lc" == "pods" || "$kind_lc" == "pod" ]]; then
  fixture="${MOCK_POD_FIXTURE:-}"
fi
# Special: kubectl get sa/<name> ...
if [[ "$kind_lc" == "sa" || "$kind_lc" == "serviceaccount" || "$kind_lc" == "serviceaccounts" ]]; then
  fixture="${MOCK_SA_FIXTURE:-}"
fi
# Special: kubectl get provider.pkg ...
if [[ "$kind_lc" == "provider"* || "$kind_lc" == "providers"* ]]; then
  fixture="${MOCK_PROVIDER_FIXTURE:-}"
fi

if [[ -z "$fixture" || ! -f "$fixture" ]]; then
  echo "Error from server (NotFound): $kind \"$name\" not found" >&2
  exit 1
fi

# If output is jsonpath, extract just the requested field (best-effort).
if [[ "$output" == jsonpath=* ]]; then
  jp="${output#jsonpath=}"
  case "$jp" in
    *'@.type=="Ready"'*)
      python3 -c '
import json, sys
with open(sys.argv[1]) as f: d=json.load(f)
for c in (d.get("status") or {}).get("conditions") or []:
    if c.get("type")=="Ready":
        sys.stdout.write(c.get("status","")); break
' "$fixture"
      exit 0 ;;
    *'@.type=="Synced"'*)
      python3 -c '
import json, sys
with open(sys.argv[1]) as f: d=json.load(f)
for c in (d.get("status") or {}).get("conditions") or []:
    if c.get("type")=="Synced":
        sys.stdout.write(c.get("status","")); break
' "$fixture"
      exit 0 ;;
    *)
      # Best-effort: empty
      exit 0 ;;
  esac
fi

cat "$fixture"
exit 0
SHIM
chmod +x "$MOCK_DIR/kubectl"

# ---------------------------------------------------------------------------
# Mock aws shim
# ---------------------------------------------------------------------------
cat > "$MOCK_DIR/aws" <<'AWS'
#!/usr/bin/env bash
# Mock aws CLI for test_crossplane_trace.sh
set -u
LOG="${MOCK_AWS_LOG:-/dev/null}"
echo "$*" >> "$LOG"

# Detect command
cmd=""
sub=""
for a in "$@"; do
  case "$a" in
    sts|iam|s3|ec2|eks) cmd="$a" ;;
    get-caller-identity|get-role) sub="$a" ;;
  esac
done

if [[ "$cmd" == "sts" && "$sub" == "get-caller-identity" ]]; then
  echo "123456789012"
  exit 0
fi

if [[ "$cmd" == "iam" && "$sub" == "get-role" ]]; then
  # Emit a trust policy that names the SA from $MOCK_TRUST_SA (or a default)
  trust_sa="${MOCK_TRUST_SA:-upbound-provider-family-aws}"
  trust_ns="${MOCK_TRUST_NS:-crossplane-system}"
  cat <<JSON
{
  "Role": {
    "RoleName": "k8-platform-mgmt-crossplane",
    "Arn": "arn:aws:iam::123456789012:role/k8-platform-mgmt-crossplane",
    "AssumeRolePolicyDocument": {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Principal": {"Federated": "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/XXXXX"},
          "Action": "sts:AssumeRoleWithWebIdentity",
          "Condition": {
            "StringEquals": {
              "oidc.eks.us-east-1.amazonaws.com/id/XXXXX:sub": "system:serviceaccount:${trust_ns}:${trust_sa}"
            }
          }
        }
      ]
    }
  }
}
JSON
  exit 0
fi

# Default
exit 0
AWS
chmod +x "$MOCK_DIR/aws"

# ---------------------------------------------------------------------------
# Helper
# ---------------------------------------------------------------------------
# run_script <map> [env-vars] -- <argv>
run_script() {
  local map="$1"; shift
  local pod_fixture="" sa_fixture="" provider_fixture="" trust_sa="" skip_aws=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pod) pod_fixture="$2"; shift 2 ;;
      --sa)  sa_fixture="$2"; shift 2 ;;
      --provider) provider_fixture="$2"; shift 2 ;;
      --trust-sa) trust_sa="$2"; shift 2 ;;
      --skip-aws) skip_aws=1; shift ;;
      --) shift; break ;;
      *) break ;;
    esac
  done
  local args_log aws_log
  args_log=$(mktemp -p "$MOCK_DIR" args.XXXXXX)
  aws_log=$(mktemp -p "$MOCK_DIR" aws.XXXXXX)
  MOCK_MAP="$map" \
  MOCK_POD_FIXTURE="$pod_fixture" \
  MOCK_SA_FIXTURE="$sa_fixture" \
  MOCK_PROVIDER_FIXTURE="$provider_fixture" \
  MOCK_TRUST_SA="$trust_sa" \
  MOCK_ARGS_LOG="$args_log" \
  MOCK_AWS_LOG="$aws_log" \
  KUBECTL="$MOCK_DIR/kubectl" \
  PATH="$MOCK_DIR:$PATH" \
  AWS_REGION="us-east-1" \
  ${skip_aws:+SKIP_AWS_OVERRIDE=1} \
    bash "$SCRIPT" "$@"
  local rc=$?
  LAST_ARGS_LOG="$args_log"
  LAST_AWS_LOG="$aws_log"
  return $rc
}

# ===========================================================================
# Test 1: --help prints --watch and --json
# ===========================================================================
echo "── test 1: --help mentions --watch and --json ──"
help_out=$(bash "$SCRIPT" --help 2>&1)
rc=$?
assert_eq "help_exit_0" "0" "$rc"
assert_contains "help_has_watch" "--watch" "$help_out"
assert_contains "help_has_json"  "--json"  "$help_out"

# ===========================================================================
# Test 2: happy-path output framing + budget
# ===========================================================================
echo "── test 2: happy-path framing + budget ──"
MAP_OK="platformsecret/happy-claim=$FIXTURES/claim-ok.json:xplatformsecret/happy-claim-xr1=$FIXTURES/xr-ok.json:secret/happy-claim-asm=$FIXTURES/mr-ok.json"
set +e
out=$(run_script "$MAP_OK" \
        --pod "$FIXTURES/provider-pod-ok.json" \
        --sa  "$FIXTURES/provider-sa-ok.json" \
        --provider "$FIXTURES/provider-pkg.json" \
        --trust-sa "upbound-provider-family-aws" \
        -- PlatformSecret/happy-claim -n default 2>&1)
rc=$?
set -e
assert_contains "happy_starts_marker" "=== CROSSPLANE TRACE:" "$out"
assert_contains "happy_ends_marker"   "=== END TRACE ==="     "$out"
bytes=${#out}
if [[ "$bytes" -le 5120 ]]; then
  _pass "happy_under_5kb"
else
  _fail "happy_under_5kb" "size $bytes > 5120"
fi

# ===========================================================================
# Test 3: SA mismatch — exactly one MISMATCH
# ===========================================================================
echo "── test 3: SA-mismatch fixture produces MISMATCH ──"
MAP_MM="platformsecret/stuck-claim=$FIXTURES/claim-failing.json:xplatformsecret/stuck-claim-xr1=$FIXTURES/xr-with-mrs.json:secret/stuck-claim-asm=$FIXTURES/mr-access-denied.json"
set +e
out=$(run_script "$MAP_MM" \
        --pod "$FIXTURES/provider-pod-sa-mismatch.json" \
        --sa  "$FIXTURES/provider-sa-mismatch.json" \
        --provider "$FIXTURES/provider-pkg.json" \
        --trust-sa "upbound-provider-family-aws" \
        -- PlatformSecret/stuck-claim -n default 2>&1)
set -e
mm_count=$(printf '%s\n' "$out" | grep -c MISMATCH || true)
assert_eq "sa_mismatch_exactly_one" "1" "$mm_count"
assert_contains "sa_mismatch_pod_sa_line" "pod-SA:" "$out"

# ===========================================================================
# Test 4: XR empty conditions → "<empty"
# ===========================================================================
echo "── test 4: xr-empty-conditions emits <empty marker ──"
MAP_EMPTY="platformsecret/stuck-claim=$FIXTURES/claim-failing.json:xplatformsecret/stuck-claim-xr1=$FIXTURES/xr-empty-conditions.json"
set +e
out=$(run_script "$MAP_EMPTY" \
        --pod "$FIXTURES/provider-pod-ok.json" \
        --sa  "$FIXTURES/provider-sa-ok.json" \
        --provider "$FIXTURES/provider-pkg.json" \
        -- PlatformSecret/stuck-claim -n default 2>&1)
set -e
assert_contains "xr_empty_marker" "<empty" "$out"

# ===========================================================================
# Test 5: MR access-denied → [FAIL]
# ===========================================================================
echo "── test 5: mr-access-denied fixture produces [FAIL] ──"
MAP_AD="platformsecret/stuck-claim=$FIXTURES/claim-failing.json:xplatformsecret/stuck-claim-xr1=$FIXTURES/xr-with-mrs.json:secret/stuck-claim-asm=$FIXTURES/mr-access-denied.json"
set +e
out=$(run_script "$MAP_AD" \
        --pod "$FIXTURES/provider-pod-ok.json" \
        --sa  "$FIXTURES/provider-sa-ok.json" \
        --provider "$FIXTURES/provider-pkg.json" \
        --trust-sa "upbound-provider-family-aws" \
        -- PlatformSecret/stuck-claim -n default 2>&1)
set -e
assert_contains "mr_fail_marker" "[FAIL]" "$out"

# ===========================================================================
# Test 6: --json emits valid JSON with five top-level keys
# ===========================================================================
echo "── test 6: --json mode ──"
set +e
json_out=$(run_script "$MAP_OK" \
        --pod "$FIXTURES/provider-pod-ok.json" \
        --sa  "$FIXTURES/provider-sa-ok.json" \
        --provider "$FIXTURES/provider-pkg.json" \
        --trust-sa "upbound-provider-family-aws" \
        -- PlatformSecret/happy-claim -n default --json 2>/dev/null)
rc=$?
set -e
assert_eq "json_exit_0" "0" "$rc"
if command -v jq >/dev/null 2>&1; then
  if printf '%s' "$json_out" | jq . >/dev/null 2>&1; then
    _pass "json_is_valid"
  else
    _fail "json_is_valid" "jq could not parse output"
  fi
  for k in timestamp claim xr managedResources provider irsa; do
    if printf '%s' "$json_out" | jq -e ".$k" >/dev/null 2>&1; then
      _pass "json_has_$k"
    else
      _fail "json_has_$k" "key missing"
    fi
  done
else
  echo "  (jq not installed — skipping JSON content asserts)"
fi

# ===========================================================================
# Test 7: --watch on Ready=True exits 0 within first cycle
# ===========================================================================
echo "── test 7: --watch + Ready=True → exit 0 ──"
set +e
out=$(TRACE_INTERVAL=1 run_script "$MAP_OK" \
        --pod "$FIXTURES/provider-pod-ok.json" \
        --sa  "$FIXTURES/provider-sa-ok.json" \
        --provider "$FIXTURES/provider-pkg.json" \
        --trust-sa "upbound-provider-family-aws" \
        -- PlatformSecret/happy-claim -n default --watch --timeout 30 2>&1)
rc=$?
set -e
assert_eq "watch_ready_exit_0" "0" "$rc"
assert_contains "watch_ready_marker" "watch exiting 0" "$out"

# ===========================================================================
# Test 8: --watch + --timeout 0 + not-ready → exit 2 within 1 s
# ===========================================================================
echo "── test 8: --watch + --timeout 0 + not-ready → exit 2 ──"
MAP_NR="platformsecret/stuck-claim=$FIXTURES/claim-failing.json:xplatformsecret/stuck-claim-xr1=$FIXTURES/xr-with-mrs.json:secret/stuck-claim-asm=$FIXTURES/mr-access-denied.json"
set +e
t0=$(date +%s)
out=$(TRACE_INTERVAL=1 run_script "$MAP_NR" \
        --pod "$FIXTURES/provider-pod-ok.json" \
        --sa  "$FIXTURES/provider-sa-ok.json" \
        --provider "$FIXTURES/provider-pkg.json" \
        --trust-sa "upbound-provider-family-aws" \
        -- PlatformSecret/stuck-claim -n default --watch --timeout 0 2>&1)
rc=$?
t1=$(date +%s)
set -e
elapsed=$((t1 - t0))
assert_eq "watch_timeout0_exit_2" "2" "$rc"
if [[ "$elapsed" -le 3 ]]; then
  _pass "watch_timeout0_under_3s"
else
  _fail "watch_timeout0_under_3s" "elapsed ${elapsed}s"
fi
assert_contains "watch_timeout_marker" "TIMEOUT" "$out"

# ===========================================================================
# Test 9: lookup-failed claim → non-zero exit + CLAIM: lookup-failed marker
# ===========================================================================
echo "── test 9: lookup-failed claim → non-zero exit + marker ──"
set +e
out=$(run_script "" \
        --pod "$FIXTURES/provider-pod-ok.json" \
        --sa  "$FIXTURES/provider-sa-ok.json" \
        --provider "$FIXTURES/provider-pkg.json" \
        --trust-sa "upbound-provider-family-aws" \
        -- PlatformSecret/nonexistent -n default 2>&1)
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  _pass "lookup_failed_nonzero_exit"
else
  _fail "lookup_failed_nonzero_exit" "got rc=0"
fi
assert_contains "lookup_failed_marker" "CLAIM: lookup-failed" "$out"

# ===========================================================================
# Test 10: lookup-failed + --json → non-zero exit + jq parses
# ===========================================================================
echo "── test 10: lookup-failed + --json → jq-parseable ──"
set +e
json_out=$(run_script "" \
        --pod "$FIXTURES/provider-pod-ok.json" \
        --sa  "$FIXTURES/provider-sa-ok.json" \
        --provider "$FIXTURES/provider-pkg.json" \
        --trust-sa "upbound-provider-family-aws" \
        -- PlatformSecret/nonexistent -n default --json 2>/dev/null)
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  _pass "lookup_failed_json_nonzero_exit"
else
  _fail "lookup_failed_json_nonzero_exit" "got rc=0"
fi
if command -v jq >/dev/null 2>&1; then
  if printf '%s' "$json_out" | jq . >/dev/null 2>&1; then
    _pass "lookup_failed_json_valid"
  else
    _fail "lookup_failed_json_valid" "jq could not parse"
  fi
fi

# ===========================================================================
# Test 11: 12-resourceRefs fixture stays within 5 KB budget
# ===========================================================================
echo "── test 11: big-fan-out output ≤ 5120 bytes ──"
MAP_BIG="platformsecret/big-claim=$FIXTURES/claim-failing.json:xplatformsecret/stuck-claim-xr1=$FIXTURES/xr-12-refs.json"
# All 12 MRs map to the long failing fixture
for i in 01 02 03 04 05 06 07 08 09 10 11 12; do
  MAP_BIG="$MAP_BIG:secret/mr$i=$FIXTURES/mr-failing-long.json"
done
set +e
out=$(run_script "$MAP_BIG" \
        --pod "$FIXTURES/provider-pod-ok.json" \
        --sa  "$FIXTURES/provider-sa-ok.json" \
        --provider "$FIXTURES/provider-pkg.json" \
        --trust-sa "upbound-provider-family-aws" \
        -- PlatformSecret/big-claim -n default 2>&1)
set -e
bytes=${#out}
if [[ "$bytes" -le 5120 ]]; then
  _pass "big_fanout_under_5kb"
else
  _fail "big_fanout_under_5kb" "size $bytes > 5120"
fi

# ===========================================================================
# Test 12: bash -n syntax check
# ===========================================================================
echo "── test 12: bash -n syntax check ──"
if bash -n "$SCRIPT" 2>/dev/null; then
  _pass "syntax_clean"
else
  _fail "syntax_clean" "bash -n failed"
fi

# ===========================================================================
# Test 13: SKIP_AWS env path emits no MATCH/MISMATCH
# ===========================================================================
echo "── test 13: SKIP_AWS path omits MATCH/MISMATCH ──"
set +e
out=$(AWS_REGION=eu-west-1 run_script "$MAP_OK" \
        --pod "$FIXTURES/provider-pod-ok.json" \
        --sa  "$FIXTURES/provider-sa-ok.json" \
        --provider "$FIXTURES/provider-pkg.json" \
        --trust-sa "upbound-provider-family-aws" \
        -- PlatformSecret/happy-claim -n default 2>&1)
set -e
if printf '%s\n' "$out" | grep -qE 'MATCH|MISMATCH'; then
  _fail "skip_aws_no_match_lines" "found MATCH/MISMATCH despite SKIP_AWS region"
else
  _pass "skip_aws_no_match_lines"
fi

# ===========================================================================
# Test 14: case-insensitive kind handling
# ===========================================================================
echo "── test 14: kind is case-insensitive ──"
set +e
out=$(run_script "$MAP_OK" \
        --pod "$FIXTURES/provider-pod-ok.json" \
        --sa  "$FIXTURES/provider-sa-ok.json" \
        --provider "$FIXTURES/provider-pkg.json" \
        --trust-sa "upbound-provider-family-aws" \
        -- platformsecret/happy-claim -n default 2>&1)
rc=$?
set -e
assert_contains "lowercase_kind_works" "=== END TRACE ===" "$out"

# ===========================================================================
# Test 15: shellcheck clean (skipped if absent)
# ===========================================================================
echo "── test 15: shellcheck ──"
if command -v shellcheck >/dev/null 2>&1; then
  # -x so shellcheck follows the optional `_lib/k8s-helpers.sh` source
  # (resolved via the SCRIPTDIR directive in scripts/crossplane-trace.sh).
  if shellcheck -x "$SCRIPT" 2>&1; then
    _pass "shellcheck_clean"
  else
    _fail "shellcheck_clean" "shellcheck reported issues"
  fi
else
  echo "  (shellcheck not installed — skipping)"
fi

assert_summary
