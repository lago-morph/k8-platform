#!/usr/bin/env bash
# One-shot session-start probe: account ID, region, EKS name, zone,
# kubectl ctx, ArgoCD URL, Crossplane version.
#
# Usage:
#   scripts/whereami.sh           # human-readable output
#   scripts/whereami.sh --json    # JSON object, suitable for jq / precondition gates
#   scripts/whereami.sh --cache   # JSON to stdout AND writes /tmp/session.env
#   scripts/whereami.sh --help    # show this usage block
#
# Exit codes:
#   0  — success (even with WARN annotations for soft mismatches)
#   1  — AWS credentials completely absent (ACCOUNT == "UNKNOWN")
#
# The script is the first consumer of scripts/_lib/aws-cli-helpers.sh.
# Per AGENTS.md §8.1: run as the first command of every session (SPEC-S4).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/_lib/aws-cli-helpers.sh
. "$SCRIPT_DIR/_lib/aws-cli-helpers.sh"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
MODE="human"
for arg in "$@"; do
  case "$arg" in
    --json)  MODE="json" ;;
    --cache) MODE="cache" ;;
    --help)
      # Print only the header comment block (lines 2–17, the usage synopsis)
      sed -n '2,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "Unknown flag: $arg" >&2
      echo "Usage: $0 [--json|--cache|--help]" >&2
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Collect all seven fields before printing (avoids interleaved slow output)
# ---------------------------------------------------------------------------
collect_fields() {
  ACCOUNT=$(aws_account_id)
  REGION=$(aws_region)
  CLUSTER=$(aws_eks_cluster)
  ZONE=$(aws_eks_zone)
  CTX=$(k8s_context)
  ARGOCD=$(argocd_url)
  XPVERSION=$(crossplane_version)
}

# Run collection with a 15-second timeout
if ! timeout 15 bash -c "
  . \"$SCRIPT_DIR/_lib/aws-cli-helpers.sh\"
  ACCOUNT=\$(aws_account_id)
  REGION=\$(aws_region)
  CLUSTER=\$(aws_eks_cluster)
  ZONE=\$(aws_eks_zone)
  CTX=\$(k8s_context)
  ARGOCD=\$(argocd_url)
  XPVERSION=\$(crossplane_version)
  # Export via stdout so the parent shell can read them
  printf '%s\n' \"\$ACCOUNT\" \"\$REGION\" \"\$CLUSTER\" \"\$ZONE\" \"\$CTX\" \"\$ARGOCD\" \"\$XPVERSION\"
" > /tmp/_whereami_fields_$$ 2>/tmp/_whereami_stderr_$$; then
  echo "ERROR: whereami.sh timed out after 15 seconds collecting environment fields." >&2
  rm -f /tmp/_whereami_fields_$$ /tmp/_whereami_stderr_$$
  exit 1
fi

# Read the seven lines into variables
{
  IFS= read -r ACCOUNT
  IFS= read -r REGION
  IFS= read -r CLUSTER
  IFS= read -r ZONE
  IFS= read -r CTX
  IFS= read -r ARGOCD
  IFS= read -r XPVERSION
} < /tmp/_whereami_fields_$$
rm -f /tmp/_whereami_fields_$$ /tmp/_whereami_stderr_$$

# ---------------------------------------------------------------------------
# Credential gate: exit 1 only if AWS credentials are absent
# ---------------------------------------------------------------------------
if [[ "$ACCOUNT" == "UNKNOWN" ]]; then
  echo "ERROR: AWS credentials are absent or invalid (aws sts get-caller-identity failed)." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

# Annotate a value with WARN if it is empty or "UNKNOWN"
annotate() {
  local val="$1"
  if [[ -z "$val" || "$val" == "UNKNOWN" ]]; then
    echo "${val:-} WARN: not available"
  else
    echo "$val"
  fi
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
case "$MODE" in
  human)
    echo "── whereami ────────────────────────────────────────────────────────"
    printf "  %-14s %s\n" "account"     "$(annotate "$ACCOUNT")"
    printf "  %-14s %s\n" "region"      "$(annotate "$REGION")"
    printf "  %-14s %s\n" "eks-cluster" "$(annotate "$CLUSTER")"
    printf "  %-14s %s\n" "zone"        "$(annotate "$ZONE")"
    printf "  %-14s %s\n" "kubectl-ctx" "$(annotate "$CTX")"
    printf "  %-14s %s\n" "argocd-url"  "$(annotate "$ARGOCD")"
    printf "  %-14s %s\n" "crossplane"  "$(annotate "$XPVERSION")"
    ;;

  json)
    # Use printf to build JSON; avoids dependency on jq for construction.
    # All fields included; empty/unknown fields appear as empty strings.
    printf '{"account":"%s","region":"%s","eksCluster":"%s","zone":"%s","kubectlCtx":"%s","argoCdUrl":"%s","crossplaneVersion":"%s"}\n' \
      "$ACCOUNT" \
      "$REGION" \
      "$CLUSTER" \
      "$ZONE" \
      "$CTX" \
      "$ARGOCD" \
      "$XPVERSION"
    ;;

  cache)
    # Emit JSON to stdout
    JSON=$(printf '{"account":"%s","region":"%s","eksCluster":"%s","zone":"%s","kubectlCtx":"%s","argoCdUrl":"%s","crossplaneVersion":"%s"}\n' \
      "$ACCOUNT" \
      "$REGION" \
      "$CLUSTER" \
      "$ZONE" \
      "$CTX" \
      "$ARGOCD" \
      "$XPVERSION")
    echo "$JSON"

    # Write KEY=value pairs to /tmp/session.env for source-ability by subagents
    {
      echo "ACCOUNT=$ACCOUNT"
      echo "REGION=$REGION"
      echo "EKS_CLUSTER=$CLUSTER"
      echo "ZONE=$ZONE"
      echo "KUBECTL_CTX=$CTX"
      echo "ARGOCD_URL=$ARGOCD"
      echo "CROSSPLANE_VERSION=$XPVERSION"
    } > /tmp/session.env
    echo "# Cached to /tmp/session.env" >&2
    ;;
esac

exit 0
