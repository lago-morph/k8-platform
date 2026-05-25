# PURPOSE:
# Shared helper functions for bash scripts that need AWS/k8s environment
# information. Sourced by scripts/whereami.sh and all later Tier S/A/C
# scripts. Never executed directly — source it with:
#   . "$SCRIPT_DIR/_lib/aws-cli-helpers.sh"
#
# Convention:
#   - aws_*  : AWS-facing helpers
#   - k8s_*  : reserved for scripts/_lib/k8s-helpers.sh (introduced by S7)
#   - argocd_* / crossplane_* : component-specific helpers
#
# Every function returns a sentinel (empty string or "UNKNOWN") on failure;
# no function may exit the calling script.

# Guard against accidental direct execution.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "ERROR: aws-cli-helpers.sh must be sourced, not executed directly." >&2
  echo "Usage: . /path/to/scripts/_lib/aws-cli-helpers.sh" >&2
  exit 2
fi

# Returns the caller's 12-digit account ID, or the string "UNKNOWN" on failure.
aws_account_id() {
  aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "UNKNOWN"
}

# Returns the resolved AWS region:
#   1. $AWS_REGION
#   2. $AWS_DEFAULT_REGION
#   3. EC2 IMDSv2 region (with a 1-second timeout so it is fast outside EC2)
#   4. "us-east-1" as last-resort fallback
aws_region() {
  if [[ -n "${AWS_REGION:-}" ]]; then
    echo "$AWS_REGION"
    return 0
  fi
  if [[ -n "${AWS_DEFAULT_REGION:-}" ]]; then
    echo "$AWS_DEFAULT_REGION"
    return 0
  fi
  local imds_region
  imds_region=$(
    TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
      -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" \
      --connect-timeout 1 --max-time 1 2>/dev/null) &&
    curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
      "http://169.254.169.254/latest/meta-data/placement/region" \
      --connect-timeout 1 --max-time 1 2>/dev/null
  )
  if [[ -n "$imds_region" ]]; then
    echo "$imds_region"
    return 0
  fi
  echo "us-east-1"
}

# Returns the first EKS cluster name in the resolved region, or empty string.
aws_eks_cluster() {
  aws eks list-clusters \
    --region "$(aws_region)" \
    --query 'clusters[0]' \
    --output text 2>/dev/null | grep -v '^None$' || true
}

# Returns the AZ of the first EKS node via kubectl, or empty string.
# Falls back gracefully if kubeconfig is not valid.
aws_eks_zone() {
  kubectl get nodes \
    -o jsonpath='{.items[0].metadata.labels.topology\.kubernetes\.io/zone}' \
    2>/dev/null || true
}

# Returns the active kubectl context name, or "(none)" if no context is set.
k8s_context() {
  kubectl config current-context 2>/dev/null || echo "(none)"
}

# Returns the ArgoCD server URL.
# Discovery order:
#   1. Ingress hostname annotated with kubernetes.io/ingress.class=nginx
#   2. LoadBalancer service hostname for argocd-server
#   3. Empty string (ArgoCD not found)
argocd_url() {
  local host
  # Try Ingress first
  host=$(kubectl get ingress -n argocd \
    -o jsonpath='{.items[0].spec.rules[0].host}' 2>/dev/null || true)
  if [[ -n "$host" ]]; then
    echo "https://$host"
    return 0
  fi
  # Fall back to LoadBalancer hostname
  host=$(kubectl get svc argocd-server -n argocd \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  if [[ -n "$host" ]]; then
    echo "https://$host"
    return 0
  fi
  echo ""
}

# Returns the Crossplane core version from the crossplane-system deployment image tag.
# Returns empty string if crossplane is not installed.
crossplane_version() {
  kubectl get deployment crossplane -n crossplane-system \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null \
    | sed 's/.*://' || true
}
