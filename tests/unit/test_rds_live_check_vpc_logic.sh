#!/usr/bin/env bash
# Pins rds-instance-live.sh's in-VPC assertion against the REAL aws-CLI
# output shape. Red-first reproduction of the clean-build-#3 false
# negative (2026-06-12): `aws ec2 describe-vpcs --query 'Vpcs[0].IsDefault'
# --output text` prints Python-capitalized `False`, the script compared
# against lowercase "false", and a correctly base-VPC-placed instance
# (the OI-2026-06-11-1 fix WORKING) was reported as the default-VPC bug.
#
# Runs the real script with a stub `aws` on PATH that answers every call
# the script makes, emitting booleans exactly as the real CLI does.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-helpers.sh"
require_tool jq

ROOT="$HERE/../.."
CHECK="$ROOT/tests/live/checks/after/rds-instance-live.sh"
[ -f "$CHECK" ] || { fail "check script present" "$CHECK missing"; summary; }

STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

cat > "$STUB_DIR/aws" <<'STUB'
#!/usr/bin/env bash
# Minimal aws stub for rds-instance-live.sh. Dispatch on subcommands.
args="$*"
case "$args" in
  *"sts get-caller-identity"*) exit 0 ;;
  *"rds describe-db-instances"*"--db-instance-identifier"*)
    # the per-instance VpcId text query
    echo "vpc-0stubbed1234567890" ;;
  *"rds describe-db-instances"*)
    echo '[{"id":"stub-db","status":"available","arn":"arn:aws:rds:us-east-1:000000000000:db:stub-db","engine":"postgres"}]' ;;
  *"rds list-tags-for-resource"*)
    echo '[{"Key":"ManagedBy","Value":"crossplane"},{"Key":"PlatformAbstraction","Value":"XDatabase"}]' ;;
  *"ec2 describe-vpcs"*)
    # The real CLI prints Python-capitalized booleans in text mode.
    echo "False" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$STUB_DIR/aws"

out="$(PATH="$STUB_DIR:$PATH" bash "$CHECK" 2>&1)"
rc=$?

if [ "$rc" -eq 0 ]; then
  pass "non-default VPC (CLI text 'False') exits PASS"
else
  fail "non-default VPC (CLI text 'False') exits PASS" "rc=$rc; output: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
fi

printf '%s' "$out" | grep -q "COVERS rds.aws.m.upbound.io/Instance" \
  && pass "covers line emitted on pass" \
  || fail "covers line emitted on pass" "no COVERS line in: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"

# And the genuine default-VPC case still fails: stub flips to True.
sed -i 's/echo "False"/echo "True"/' "$STUB_DIR/aws"
out2="$(PATH="$STUB_DIR:$PATH" bash "$CHECK" 2>&1)"
rc2=$?
if [ "$rc2" -ne 0 ] && [ "$rc2" -ne 2 ]; then
  pass "default VPC (CLI text 'True') still exits FAIL"
else
  fail "default VPC (CLI text 'True') still exits FAIL" "rc=$rc2"
fi

# INDETERMINATE case (live-verify run 28759141867, 2026-07-05): under the
# scoped verifier role ec2:DescribeVpcs was NOT granted — the query printed
# NOTHING (empty, rc≠0) and the check misattributed "cannot determine" to
# the OI-2026-06-11-1 default-VPC bug. Empty is not "true": the check must
# fail with an it's-the-caller's-permissions diagnosis, never the
# placement-bug one.
sed -i 's/echo "True"/exit 254/' "$STUB_DIR/aws"
out3="$(PATH="$STUB_DIR:$PATH" bash "$CHECK" 2>&1)"
rc3=$?
if [ "$rc3" -ne 0 ] && [ "$rc3" -ne 2 ]; then
  pass "indeterminate IsDefault (DescribeVpcs denied) still exits FAIL"
else
  fail "indeterminate IsDefault exits FAIL" "rc=$rc3"
fi
printf '%s' "$out3" | grep -qi "cannot determine" \
  && pass "indeterminate case says 'cannot determine', names the permission" \
  || fail "indeterminate case diagnosis" "must say the VPC default-ness could not be determined (missing ec2:DescribeVpcs?), got: $(printf '%s' "$out3" | tail -2 | tr '\n' ' ')"
printf '%s' "$out3" | grep -q "OI-2026-06-11-1" \
  && fail "indeterminate case must NOT claim the placement bug" "misattribution: $(printf '%s' "$out3" | tail -2 | tr '\n' ' ')" \
  || pass "indeterminate case does not claim the placement bug"

summary
