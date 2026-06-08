#!/usr/bin/env bash
# LIVE behavioral check (instantiate tier) — CREATE a real Secrets Manager secret
# through the Crossplane controller, prove it converged + the real ASM secret
# exists, then ALWAYS delete it (FINAL-PLAN §P4; ADR-0006).
#
# secretsmanager.aws.m.upbound.io/Secret is ONE of the two reviewer-approved
# hermetic standalone roots (planning/test-overhaul/decisions/
# auto-014-001-cost-tier-assignments.md).
#
# XPlatformSecret-vs-bare-MR DECISION (brief item 2): we instantiate a BARE
# namespaced `secretsmanager.aws.m.upbound.io/Secret` MR, NOT the XPlatformSecret
# claim. Rationale, read straight off crossplane/compositions/platform-secret.yaml:
# the XPlatformSecret Composition renders TWO resources — the ASM Secret AND an
# ESO ExternalSecret whose readinessCheck is `MatchCondition Ready=True`. That
# ExternalSecret is singleton-coupled: it only goes Ready once the shared
# `aws-secrets-manager` ClusterSecretStore (a long-lived platform singleton) +
# the ESO controller successfully sync it. So an XPlatformSecret XR's readiness
# depends on a singleton — exactly the heavier-grade coupling the brief says to
# avoid. The bare ASM Secret MR is the genuinely hermetic standalone root: it
# converges purely from the controller + its IRSA, with no foreign key. (It does
# NOT pull in KMS/replica/policy — the Composition's ASM Secret base carries none
# of those either.)
#
# Drives the REAL controller under its scoped IRSA — NOT an admin-AWS write. The
# secret external-name is k8-platform/live-verify-<RUN_ID> so the controller's
# secretsmanager:CreateSecret (scoped to secret:k8-platform/* in
# terraform/management/irsa.tf) succeeds rather than failing closed.
# recoveryWindowInDays=0 so the delete is immediate (no 7-day window blocking
# re-creates / leaving a scheduled-for-deletion shell), matching the Composition.
#
# SECURITY (ADR-0006 NON-GOAL + FINAL-PLAN §9.2): NEVER calls get-secret-value;
# NEVER sets/prints/decodes secret material. The MR is created value-less;
# verification is existence + crossplane-kind/live-verify tag ONLY.
#
# Exit-code contract (tests/live/lib/live-lib.sh): 0=pass(+covers), 2=skip,
# 3=expect-full, other=fail. Create-path => runs ONLY in LIVE_MODE=mutating;
# readonly SKIPs without applying anything.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
# shellcheck source=/dev/null
. "$REPO_ROOT/tests/live/lib/instantiate-lib.sh"

KIND="secretsmanager.aws.m.upbound.io/Secret"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
SECRET_EXTERNAL_NAME="k8-platform/live-verify-${RUN_ID:?RUN_ID must be set}"
MR_NAME="live-verify-secret-${RUN_ID}"
MR_KIND="secret.secretsmanager.aws.m.upbound.io"

# render_secret <run_id> <epoch> — print the namespaced ASM Secret MR manifest.
# Carries BOTH reaper tags. No secret value is set (value-less container — we
# only verify the container exists, never its material).
render_secret() {
  local run_id="$1" epoch="$2"
  cat <<YAML
apiVersion: secretsmanager.aws.m.upbound.io/v1beta1
kind: Secret
metadata:
  name: ${MR_NAME}
  annotations:
    crossplane.io/external-name: ${SECRET_EXTERNAL_NAME}
  labels:
    test.k8-platform/live-verify: "true"
spec:
  forProvider:
    region: ${REGION}
    recoveryWindowInDays: 0
    tags:
      ManagedBy: crossplane
      PlatformAbstraction: LiveVerify
      ${IV_TAG_RUNID_KEY}: "${run_id}"
      ${IV_TAG_CREATED_KEY}: "${epoch}"
  managementPolicies: [Observe, Create, Update, Delete]
  providerConfigRef:
    kind: ClusterProviderConfig
    name: default
YAML
}

# verify_secret <run_id> — prove the REAL ASM secret this run created exists and
# is crossplane-provisioned + live (not scheduled for deletion). REUSES the
# after-tier oracle's selection logic (tests/live/checks/after/
# secretsmanager-secret-live.sh): select by tag, require crossplane-kind AND this
# run's live-verify tag, and confirm DeletedDate is null. Existence-only — NEVER
# reads the secret value (security NON-GOAL).
verify_secret() {
  local run_id="$1"
  for bin in aws jq; do
    command -v "$bin" >/dev/null 2>&1 || { ng "$bin not on PATH (cannot verify the created ASM secret)"; return 1; }
  done
  aws sts get-caller-identity >/dev/null 2>&1 || { ng "no usable AWS credentials to verify the created ASM secret"; return 1; }

  # describe-secret returns Name/Tags/DeletedDate but NO secret material.
  local describe
  describe="$(aws secretsmanager describe-secret \
                --secret-id "$SECRET_EXTERNAL_NAME" --region "$REGION" \
                --output json 2>/dev/null)" \
    || { ng "created secret $SECRET_EXTERNAL_NAME not found via secretsmanager:DescribeSecret"; return 1; }

  # Live (not scheduled for deletion)?
  local deleted
  deleted="$(printf '%s' "$describe" | jq -r '.DeletedDate // "null"')"
  if [ "$deleted" != "null" ]; then
    ng "secret $SECRET_EXTERNAL_NAME exists but is scheduled for deletion (DeletedDate=$deleted) — not a live product"
    return 1
  fi

  # Same selector shape as the after-tier check: crossplane-kind must mark it as
  # the provider's Secret, AND it must carry THIS run's live-verify tag.
  local verdict
  verdict="$(printf '%s' "$describe" | jq -r --arg rid "$run_id" '
    (.Tags // []) | (map({(.Key): .Value}) | add // {}) as $t
    | if ($t["crossplane-kind"] == "secret.secretsmanager.aws.m.upbound.io")
         and ($t["live-verify"] == $rid)
      then "yes" else "no" end')"
  if [ "$verdict" != "yes" ]; then
    ng "secret $SECRET_EXTERNAL_NAME exists but is not tagged crossplane-kind=secret.secretsmanager.aws.m.upbound.io + live-verify=$run_id"
    return 1
  fi
  ok "real ASM secret '$SECRET_EXTERNAL_NAME' exists (live), crossplane-provisioned, tagged live-verify=$run_id"
  return 0
}

instantiate_and_verify "$KIND" render_secret verify_secret "$MR_KIND" "$MR_NAME"
