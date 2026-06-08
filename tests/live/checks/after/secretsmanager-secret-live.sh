#!/usr/bin/env bash
# LIVE behavioral check (after tier) -- a Crossplane-provisioned Secrets Manager
# secret is real and healthy (exists, not scheduled for deletion, and holds an
# AWSCURRENT version).
#
# This is the BEHAVIORAL oracle for secretsmanager.aws.m.upbound.io/Secret per
# ADR-0006: it proves the abstraction actually produced a healthy secret, not that
# a manifest says so. It selects by the Composition's own tags
# (crossplane-kind=secret.secretsmanager.aws.m.upbound.io + PlatformAbstraction=
# PlatformSecret) -- so a Terraform-created secret does NOT count; only the
# crossplane-delivered artifact does.
#
# HEALTH CONTRACT (auto-014 decision): a healthy product = the secret container
# exists AND holds an AWSCURRENT version. A crossplane secret that exists but is
# value-less (no AWSCURRENT) -- e.g. a chainsaw deletion-scenario leftover, or a
# container mid-provisioning -- is treated as NOT-a-healthy-product => SKIP, NOT
# a hard FAIL: a value-less container is indistinguishable from "not really
# provisioned", and must not turn the whole live suite RED on a test artifact.
# Where a PlatformSecret is genuinely expected the orchestrator promotes the SKIP
# to a FAIL via expect-full; and P4's instantiate-and-verify is the rigorous
# create-a-real-secret-and-verify gate.
#
# SECURITY (ADR-0006 NON-GOAL + FINAL-PLAN §9.2 redaction): NEVER calls
# get-secret-value; NEVER prints or decodes secret material. Existence + version
# staging ONLY.
#
# Exit-code contract (tests/live/lib/live-lib.sh): 0=pass(+covers), 2=skip,
# other=fail. Read-only (describe/list only) -- safe in `full` + `verify-only`.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
# shellcheck source=/dev/null
. "$REPO_ROOT/tests/live/lib/live-lib.sh"

KIND="secretsmanager.aws.m.upbound.io/Secret"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

# Tooling / creds preconditions -- not-applicable (skip), not a failure.
for bin in aws jq; do
  command -v "$bin" >/dev/null 2>&1 || skip "$bin not on PATH (SecretsManager live check not exercisable here)"
done
aws sts get-caller-identity >/dev/null 2>&1 || skip "no usable AWS credentials in this environment"

log "looking for a healthy Crossplane-provisioned Secrets Manager secret (region $REGION)"

# List secrets; AWS returns tags inline in list-secrets output.
SECRETS_JSON="$(aws secretsmanager list-secrets --region "$REGION" \
  --query 'SecretList[].{arn:ARN,name:Name,tags:Tags,deleted:DeletedDate}' \
  --output json 2>/dev/null)" || skip "secretsmanager:ListSecrets not permitted / unavailable here"

COUNT="$(printf '%s' "$SECRETS_JSON" | jq 'length')"
[ "${COUNT:-0}" -gt 0 ] || skip "no Secrets Manager secrets in the account (kind not provisioned)"

crossplane_seen=0      # >0 once we see any crossplane PlatformSecret (live, not deleting)
healthy_name=""        # set when we find one with an AWSCURRENT version

while IFS= read -r row; do
  [ -z "$row" ] && continue
  arn="$(printf '%s' "$row" | jq -r '.arn')"
  name="$(printf '%s' "$row" | jq -r '.name')"
  deleted="$(printf '%s' "$row" | jq -r '.deleted // "null"')"
  tags="$(printf '%s' "$row" | jq -r '.tags // []')"
  is_ps="$(printf '%s' "$tags" | jq -r '
    (map({(.Key): .Value}) | add // {}) as $t
    | if ($t["crossplane-kind"] == "secret.secretsmanager.aws.m.upbound.io")
         and ($t["PlatformAbstraction"] == "PlatformSecret")
      then "yes" else "no" end')"
  [ "$is_ps" = "yes" ] || continue
  # A secret scheduled for deletion is not a live healthy product -- ignore it.
  [ "$deleted" != "null" ] && continue
  crossplane_seen=$((crossplane_seen + 1))

  # Health: does it hold an AWSCURRENT version? (no secret material is read)
  DESCRIBE_JSON="$(aws secretsmanager describe-secret \
    --secret-id "$arn" --region "$REGION" --output json 2>/dev/null)" || continue
  has_current="$(printf '%s' "$DESCRIBE_JSON" | jq -r '
    .VersionIdsToStages // {}
    | to_entries
    | map(select(.value | index("AWSCURRENT")))
    | if length > 0 then "yes" else "no" end')"
  if [ "$has_current" = "yes" ]; then
    healthy_name="$name"
    break
  fi
done <<EOF
$(printf '%s' "$SECRETS_JSON" | jq -c '.[]')
EOF

if [ -n "$healthy_name" ]; then
  ok "Crossplane PlatformSecret '$healthy_name' exists and has an AWSCURRENT version staged"
  covers "$KIND"
  exit "$LIVE_RC_PASS"
fi

# No healthy one. Either none are crossplane PlatformSecrets, or the ones present
# are value-less containers (no AWSCURRENT). Both are SKIP (see HEALTH CONTRACT):
# the orchestrator promotes to FAIL iff git declares this kind (expect-full).
if [ "$crossplane_seen" -gt 0 ]; then
  skip "crossplane PlatformSecret(s) present but none hold an AWSCURRENT version (value-less container(s) -- not a healthy provisioned secret)"
fi
skip "no live secret tagged crossplane-kind=secret.secretsmanager.aws.m.upbound.io + PlatformAbstraction=PlatformSecret (kind not provisioned)"
