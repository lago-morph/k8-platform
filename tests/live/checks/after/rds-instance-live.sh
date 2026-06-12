#!/usr/bin/env bash
# LIVE behavioral check (after tier) — a Crossplane-provisioned RDS instance is
# real and healthy (the gating home for RDS coverage after the nightly/non-gating
# lane was excised, OI-2026-06-06-4 / burndown item 2 -> item 4).
#
# This is the BEHAVIORAL oracle for rds.aws.m.upbound.io/Instance per ADR-0006:
# it proves the XDatabase abstraction actually produced a healthy RDS instance,
# not that a manifest says so. It looks for a live RDS instance carrying the
# Composition's own tag (PlatformAbstraction=XDatabase) in DBInstanceStatus
# "available" — so a Terraform-created DB (e.g. terraform-*) does NOT count;
# only the crossplane-delivered artifact does.
#
# Exit-code contract (tests/live/lib/live-lib.sh): 0=pass(+covers), 2=skip,
# 3=expect-full violation, other=fail. Read-only (describe/list only) — safe in
# `full` + `verify-only`.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
# shellcheck source=/dev/null
. "$REPO_ROOT/tests/live/lib/live-lib.sh"

KIND="rds.aws.m.upbound.io/Instance"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

# Tooling / creds preconditions — not-applicable (skip), not a failure.
for bin in aws jq; do
  command -v "$bin" >/dev/null 2>&1 || skip "$bin not on PATH (RDS live check not exercisable here)"
done
aws sts get-caller-identity >/dev/null 2>&1 || skip "no usable AWS credentials in this environment"

log "looking for a Crossplane XDatabase-provisioned RDS instance (region $REGION)"

# Enumerate RDS instances; for each, read its tags and select the one the
# XDatabase Composition stamps (ManagedBy=crossplane, PlatformAbstraction=XDatabase).
INSTANCES_JSON="$(aws rds describe-db-instances --region "$REGION" \
  --query 'DBInstances[].{id:DBInstanceIdentifier,status:DBInstanceStatus,arn:DBInstanceArn,engine:Engine}' \
  --output json 2>/dev/null)" || skip "rds:DescribeDBInstances not permitted / unavailable here"

COUNT="$(printf '%s' "$INSTANCES_JSON" | jq 'length')"
[ "${COUNT:-0}" -gt 0 ] || skip "no RDS instances in the account (XDatabase path not provisioned)"

found_id=""; found_status=""
while IFS= read -r row; do
  [ -z "$row" ] && continue
  arn="$(printf '%s' "$row" | jq -r '.arn')"
  id="$(printf '%s' "$row" | jq -r '.id')"
  status="$(printf '%s' "$row" | jq -r '.status')"
  tags="$(aws rds list-tags-for-resource --resource-name "$arn" --region "$REGION" \
            --query 'TagList' --output json 2>/dev/null)" || continue
  is_xdb="$(printf '%s' "$tags" | jq -r '
    (map({(.Key): .Value}) | add) as $t
    | if ($t["PlatformAbstraction"] == "XDatabase") then "yes" else "no" end')"
  if [ "$is_xdb" = "yes" ]; then
    found_id="$id"; found_status="$status"
    break
  fi
done <<EOF
$(printf '%s' "$INSTANCES_JSON" | jq -c '.[]')
EOF

# No XDatabase-tagged instance ⇒ the kind is unprovisioned for this account.
# Return SKIP; the orchestrator promotes it to a FAIL iff git declares the kind
# (expect-full) — which it does (tests/coverage/expected-coverage.txt), so an
# account that never synced an XDatabase will correctly go RED here.
if [ -z "$found_id" ]; then
  skip "no RDS instance tagged PlatformAbstraction=XDatabase (the XDatabase abstraction has not provisioned one)"
fi

if [ "$found_status" != "available" ]; then
  ng "XDatabase RDS instance '$found_id' is '$found_status', not 'available'"
  exit 1
fi

# In-VPC placement (OI-2026-06-11-1, found by clean build #2): the instance
# must sit in a NON-default VPC (the base VPC the platform clusters share) —
# in the default VPC it is unreachable from every consumer. This is the
# behavioral oracle for the composed SubnetGroup + SecurityGroup (coverage
# registry defended_by for rds SubnetGroup / ec2 SecurityGroup).
inst_vpc="$(aws rds describe-db-instances --db-instance-identifier "$found_id"   --region "$REGION" --query 'DBInstances[0].DBSubnetGroup.VpcId' --output text 2>/dev/null)"
vpc_is_default="$(aws ec2 describe-vpcs --vpc-ids "$inst_vpc"   --region "$REGION" --query 'Vpcs[0].IsDefault' --output text 2>/dev/null)"
if [ "$vpc_is_default" != "false" ]; then
  ng "XDatabase RDS instance '$found_id' is in VPC '$inst_vpc' (IsDefault=$vpc_is_default) — the default-VPC placement bug (OI-2026-06-11-1); composed SubnetGroup/SecurityGroup not in effect"
  exit 1
fi
log "instance '$found_id' is in non-default VPC $inst_vpc (composed SubnetGroup placement in effect)"

ok "XDatabase-provisioned RDS instance '$found_id' is available"
covers "$KIND"
exit "$LIVE_RC_PASS"
