#!/usr/bin/env bash
# Current PolicyReport violations across all namespaces.
# By default, prints one line per fail/warn result. Use --verbose for full
# message text.
# Usage: scripts/kyverno-violations.sh [--verbose] [--policy <name>] [--ns <namespace>]

set -uo pipefail

VERBOSE=0
POLICY_FILTER=""
NS_FILTER=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)    sed -n '2,5p' "$0"; exit 0 ;;
    -v|--verbose) VERBOSE=1; shift ;;
    --policy)     POLICY_FILTER="$2"; shift 2 ;;
    --ns)         NS_FILTER="$2"; shift 2 ;;
    *) echo "unknown arg: $1"; exit 1 ;;
  esac
done

JQ_FILTER='.items[] |
  .metadata.namespace as $ns
  | .results[]?
  | select(.result == "fail" or .result == "warn")
  | {
      ns: ($ns // "(cluster)"),
      policy: .policy,
      rule: .rule,
      result: .result,
      message: .message,
      resource: (.resources[0].kind + "/" + (.resources[0].name // "?"))
    }'

if [ -n "$POLICY_FILTER" ]; then
  JQ_FILTER="$JQ_FILTER | select(.policy == \"$POLICY_FILTER\")"
fi
if [ -n "$NS_FILTER" ]; then
  JQ_FILTER="$JQ_FILTER | select(.ns == \"$NS_FILTER\")"
fi

# Both kinds of reports exist: PolicyReport (namespaced) and
# ClusterPolicyReport (cluster-scoped). Query both.
DATA=$(kubectl get policyreports.wgpolicyk8s.io -A -o json 2>/dev/null)
CDATA=$(kubectl get clusterpolicyreports.wgpolicyk8s.io -o json 2>/dev/null)

echo "── namespaced violations ──────────────────────────────────────────"
if [ "$VERBOSE" -eq 1 ]; then
  echo "$DATA" | jq -r "$JQ_FILTER | [.ns, .resource, .policy, .rule, .result] | @tsv" \
    | column -t -s $'\t' | sed 's/^/  /' || true
  echo ""
  echo "── messages ───────────────────────────────────────────────────────"
  echo "$DATA" | jq -r "$JQ_FILTER | \"  \(.policy)/\(.rule)  \(.resource) [\(.ns)]\n    \(.message)\"" || true
else
  echo "$DATA" | jq -r "$JQ_FILTER | [.ns, .resource, .policy, .result] | @tsv" \
    | column -t -s $'\t' | sed 's/^/  /' || true
fi

echo ""
echo "── cluster-scoped violations ──────────────────────────────────────"
echo "$CDATA" | jq -r "$JQ_FILTER | [.resource, .policy, .result] | @tsv" \
  | column -t -s $'\t' | sed 's/^/  /' || true
