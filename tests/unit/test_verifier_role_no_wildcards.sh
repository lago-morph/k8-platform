#!/usr/bin/env bash
# K=0 ceiling lint for the scoped verifier/reaper policy (FINAL-PLAN §3.3/§3.4).
#
# The verifier/reaper harness identity is itself a least-privilege deliverable.
# The §3.3 ceiling lint covers its policy file at K=0 — NO wildcard tolerated in
# any Action (no `service:*`, no `verb*`). Reaper deletes must be tag-conditioned
# (or ARN-scoped) in the policy itself, so a bug in the runtime three-predicate
# AND (the thing under test) cannot, under admin, delete real infrastructure.

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

. tests/lib/assert.sh

POLICY=terraform/management/policies/verifier-reaper-policy.json.tftpl
TF=terraform/management/verifier_role.tf

echo "── verifier policy: valid JSON ───────────────────────────────"
if python3 -c "import json,sys; json.load(open('$POLICY'))" 2>/dev/null; then
  _pass "policy template parses as JSON (\${} tokens are valid JSON strings)"
else
  _fail "policy template parses as JSON" "json.load failed"
fi

echo ""
echo "── verifier policy: K=0 — NO wildcard in any Action ──────────"
wild="$(python3 - "$POLICY" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
bad = []
for s in d.get("Statement", []):
    acts = s.get("Action", [])
    if isinstance(acts, str): acts = [acts]
    for a in acts:
        if "*" in a:
            bad.append(a)
print("\n".join(bad))
PY
)"
assert_eq "no Action element contains '*' (K=0)" "" "$wild"

echo ""
echo "── verifier policy: every reaper DELETE is constrained ───────"
# Each mutating Delete*/Change* action must live in a statement that is EITHER
# tag-conditioned OR ARN-scoped (Resource != "*").
unconstrained="$(python3 - "$POLICY" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
bad = []
for s in d.get("Statement", []):
    acts = s.get("Action", [])
    if isinstance(acts, str): acts = [acts]
    mutating = [a for a in acts if any(v in a for v in ("Delete", "ChangeResourceRecordSets"))]
    if not mutating:
        continue
    has_cond = bool(s.get("Condition"))
    res = s.get("Resource", "*")
    arn_scoped = res != "*" and not (isinstance(res, list) and "*" in res)
    if not (has_cond or arn_scoped):
        bad.extend(mutating)
print("\n".join(bad))
PY
)"
assert_eq "every reaper delete is tag-conditioned or ARN-scoped" "" "$unconstrained"

echo ""
echo "── verifier policy: GetSecretValue is scoped to live-verify/* ─"
# Synthetic-secret-only: GetSecretValue must NOT be on Resource "*".
secret_scope="$(python3 - "$POLICY" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for s in d.get("Statement", []):
    acts = s.get("Action", [])
    if isinstance(acts, str): acts = [acts]
    if "secretsmanager:GetSecretValue" in acts:
        print(s.get("Resource", "*"))
PY
)"
assert_contains "GetSecretValue scoped to live-verify/* secrets" "live-verify/" "$secret_scope"
assert_eq "GetSecretValue not on Resource '*'" "" "$(printf '%s' "$secret_scope" | grep -Fx '*' || true)"

echo ""
echo "── verifier role tf: NON-GOAL boundary + assume-role split ───"
assert_contains "tf renders the policy template" "verifier-reaper-policy.json.tftpl" "$(cat "$TF")"
assert_contains "tf documents the NON-GOAL (not a controller principal)" "NOT a new AssumeRole principal that impersonates" "$(cat "$TF")"
assert_contains "role name is the live verifier/reaper" "live-verifier-reaper" "$(cat "$TF")"

assert_summary
