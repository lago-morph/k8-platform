#!/usr/bin/env bash
# Compare the IAM policies declared in terraform/management/irsa.tf against
# fixture lists of required actions per component. Catches the underscoped-
# IAM-policy bug class (bug #6 from 2026-05-23 phase-1 bring-up —
# external-dns had ListHostedZonesByName but not ListHostedZones, so the pod
# ran but every reconcile loop produced AccessDenied).
#
# Each fixture file under tests/unit/fixtures/iam/<component>.txt lists the
# required actions, one per line. The test asserts irsa.tf contains every
# required action somewhere inside the matching aws_iam_policy block.
#
# Wildcards (action:*) in the policy are also accepted — if a policy grants
# "route53:*", "route53:ListHostedZones" is satisfied. We do this with a
# simple substring rule: required "X:Y" is satisfied by "X:Y" OR "X:*".
#
# Wildcards within an action ("eks:Describe*") are accepted too: required
# "eks:DescribeCluster" is satisfied by "eks:Describe*".

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-helpers.sh"

ROOT="$HERE/../.."
IRSA_TF="$ROOT/terraform/management/irsa.tf"
FIXT="$HERE/fixtures/iam"

[ -f "$IRSA_TF" ] || { echo "missing $IRSA_TF"; exit 2; }

# Map fixture file → IAM policy resource name in irsa.tf.
# Each row: <fixture-stem>|<terraform resource name>
declare -a MAP=(
  "external-dns|route53_editor"
  "eso|eso"
  "crossplane-aws|crossplane_aws"
)

# Extract the action list for a given aws_iam_policy resource from irsa.tf.
# Returns one action per line on stdout.
extract_policy_actions() {
  local res="$1"
  # Find the block: resource "aws_iam_policy" "<res>" { ... } and yank lines
  # that look like "<spaces>\"<service>:<verb>\",". This is intentionally
  # blunt — it matches actions across all Statement entries in the resource.
  awk -v res="$res" '
    $0 ~ "resource \"aws_iam_policy\" \"" res "\"" { in_res=1; depth=0 }
    in_res {
      # Track brace depth to detect end of resource.
      for (i=1; i<=length($0); i++) {
        c=substr($0,i,1)
        if (c=="{") depth++
        else if (c=="}") { depth--; if (depth==0) { in_res=0; print "__END__"; next } }
      }
      print
    }
  ' "$IRSA_TF" \
    | grep -oE '"[a-zA-Z0-9]+:[a-zA-Z0-9\*]+"' \
    | tr -d '"' \
    | sort -u
}

# is_action_granted <required> <granted-list-file>
# Returns 0 if required action is present (exact, wildcard prefix, or service:*).
is_action_granted() {
  local req="$1" granted_file="$2"
  local service="${req%%:*}"
  local verb="${req##*:}"

  # Exact match.
  if grep -qxF "$req" "$granted_file"; then return 0; fi
  # Service-wide wildcard: service:*
  if grep -qxF "${service}:*" "$granted_file"; then return 0; fi
  # Prefix wildcard: e.g. eks:Describe*  satisfies  eks:DescribeCluster.
  while IFS= read -r g; do
    [[ "$g" == "${service}:"*"*" ]] || continue
    local prefix="${g%\*}"        # e.g. eks:Describe
    if [[ "$req" == "$prefix"* ]]; then return 0; fi
  done < "$granted_file"
  return 1
}

GRANTED_TMP=$(mktemp -d)
trap 'rm -rf "$GRANTED_TMP"' EXIT

for row in "${MAP[@]}"; do
  fixture="${row%%|*}"
  resource="${row##*|}"
  required_file="$FIXT/${fixture}.txt"
  granted_file="$GRANTED_TMP/$resource.txt"

  [ -f "$required_file" ] || { fail "$fixture: required-actions fixture missing"; continue; }

  extract_policy_actions "$resource" > "$granted_file"

  if [ ! -s "$granted_file" ]; then
    fail "$fixture: policy '$resource' has no actions in irsa.tf"
    continue
  fi

  echo "── iam-required-actions: $fixture ────────────────────────────────"
  while IFS= read -r line; do
    # Strip comments and blank lines from fixture.
    line="${line%%#*}"
    line="${line//[[:space:]]/}"
    [ -z "$line" ] && continue

    if is_action_granted "$line" "$granted_file"; then
      pass "$fixture: $line"
    else
      fail "$fixture: $line missing from policy $resource"
    fi
  done < "$required_file"
done

summary
