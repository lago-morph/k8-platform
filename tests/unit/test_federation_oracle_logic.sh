#!/usr/bin/env bash
# Pins the two locally-decidable behaviors of the federation oracle
# (tests/live/checks/instantiate/cognito-federation-live.sh):
#
#   1. MODE GATE — in LIVE_MODE=readonly the check exits 2 (skip) BEFORE
#      touching any tool or credential: the CI producer runs the suite
#      readonly, and a fixture-user write leaking into that path would be
#      an admin-AWS mutation under the scoped verifier role (and a
#      tier-contract violation). The stub PATH proves nothing else runs:
#      any aws/curl/kubectl invocation fails the test.
#
#   2. CLAIM DECODE — the exact id_token payload pipeline the check uses
#      (base64url + padding fix + jq assertions) against fixture JWTs:
#      the happy shape, a groups-missing shape, and a groups-as-string
#      shape (Keycloak emits a bare string when multivalued is off — the
#      jq `type == "array"` branch must handle both).
#
# The full flow (hosted UI → broker → token → kubectl) is live-only by
# nature; its hosted-UI leg was verified standalone against the real pool
# on build #5, and the whole path first runs recorded on the next
# from-scratch build.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-helpers.sh"
require_tool jq
require_tool python3

ROOT="$HERE/../.."
CHECK="$ROOT/tests/live/checks/instantiate/cognito-federation-live.sh"
[ -f "$CHECK" ] || { fail "check script present" "$CHECK missing"; summary; }
pass "check script present"

# ---- 1. readonly mode gate skips before any tool runs --------------------
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT
for tool in aws curl kubectl python3; do
  cat > "$STUB_DIR/$tool" <<STUB
#!/usr/bin/env bash
echo "UNEXPECTED: $tool invoked in readonly mode" >&2
exit 99
STUB
  chmod +x "$STUB_DIR/$tool"
done

set +e
out="$(PATH="$STUB_DIR:$PATH" LIVE_MODE=readonly bash "$CHECK" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 2 ] \
  && pass "readonly mode exits 2 (skip)" \
  || fail "readonly mode gate" "rc=$rc, output: $(printf '%s' "$out" | head -2)"
printf '%s' "$out" | grep -q "UNEXPECTED" \
  && fail "readonly mode runs no tools" "a stubbed tool was invoked: $out" \
  || pass "readonly mode runs no tools"
printf '%s' "$out" | grep -qi "mutating" \
  && pass "skip message names the mutating-mode requirement" \
  || fail "skip message" "got: $out"

# ---- 2. the id_token claim-decode pipeline --------------------------------
# Mirrors the check's pipeline byte-for-byte:
#   cut -d. -f2 | python3 (urlsafe b64 + padding) → jq assertions.
decode() {
  printf '%s' "$1" | cut -d. -f2 | python3 -c 'import sys,base64,json; p=sys.stdin.read().strip(); p+="="*(-len(p)%4); print(json.dumps(json.loads(base64.urlsafe_b64decode(p))))'
}
mk_jwt() {  # $1 = payload json → unsigned fixture JWT (header.payload.sig)
  python3 -c 'import sys,base64,json
enc=lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
h=enc(json.dumps({"alg":"RS256","typ":"JWT"}).encode())
p=enc(sys.argv[1].encode())
print(f"{h}.{p}.fixture-signature")' "$1"
}

JWT_GOOD="$(mk_jwt '{"preferred_username":"oracle-x@test.invalid","groups":["k8s-viewers","other"]}')"
CLAIMS="$(decode "$JWT_GOOD")"
[ "$(printf '%s' "$CLAIMS" | jq -r '.preferred_username')" = "oracle-x@test.invalid" ] \
  && pass "decode: preferred_username extracted" \
  || fail "decode preferred_username" "claims: $CLAIMS"
HAS="$(printf '%s' "$CLAIMS" | jq -r --arg g "k8s-viewers" '(.groups // []) | if type == "array" then any(. == $g) else . == $g end')"
[ "$HAS" = "true" ] \
  && pass "decode: groups array membership detected" \
  || fail "groups array" "claims: $CLAIMS"

JWT_STR="$(mk_jwt '{"preferred_username":"u@x","groups":"k8s-viewers"}')"
HAS="$(decode "$JWT_STR" | jq -r --arg g "k8s-viewers" '(.groups // []) | if type == "array" then any(. == $g) else . == $g end')"
[ "$HAS" = "true" ] \
  && pass "decode: groups-as-bare-string handled" \
  || fail "groups string form" "single-string groups claim must satisfy the membership test"

JWT_NONE="$(mk_jwt '{"preferred_username":"u@x"}')"
HAS="$(decode "$JWT_NONE" | jq -r --arg g "k8s-viewers" '(.groups // []) | if type == "array" then any(. == $g) else . == $g end')"
[ "$HAS" = "false" ] \
  && pass "decode: absent groups claim is a miss, not an error" \
  || fail "groups absent form" "got '$HAS'"

summary
