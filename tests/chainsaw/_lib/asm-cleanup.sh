# tests/chainsaw/_lib/asm-cleanup.sh
#
# ASM (AWS Secrets Manager) cleanup helpers for the chainsaw harness.
# Sourced by tests/chainsaw/run.sh's cleanup() trap, and exercised directly
# (with stubbed kubectl/aws on PATH) by
# tests/unit/test_chainsaw_asm_cleanup.sh. Sourcing has NO side effects —
# it only defines functions + one constant.
#
# WHY THIS EXISTS (OI-2026-05-28-1 "ASM cleanup-trap gap"):
#   The Composition crossplane/compositions/platform-secret.yaml names each
#   ASM secret `k8-platform/<XR-uid>` — a FIXED `k8-platform/` prefix that
#   does NOT contain the chainsaw run id. The previous cleanup filtered AWS
#   by `${ASM_RUN_PREFIX}/` (= `k8-platform-chainsaw-<id>/`), which can NEVER
#   match the real names, so every run's secrets leaked into the shared
#   account. We instead enumerate the real names straight from the Secret
#   managed resources (MRs) in the still-alive kind cluster — precisely the
#   secrets THIS run created — and delete exactly those. This is also safe in
#   a shared account: production `k8-platform/*` secrets have no MR in this
#   ephemeral cluster, so they are never enumerated.
#
#   The enumerate step MUST run BEFORE `kind delete cluster` (the cluster has
#   to be alive to list the MRs). run.sh's trap orders it that way; the
#   ordering is guarded statically by the unit test.

# The MR resource the Composition renders for the ASM secret. Keep in sync
# with the `asm-secret` base.apiVersion in
# crossplane/compositions/platform-secret.yaml
# (secretsmanager.aws.m.upbound.io/v1beta1, kind Secret).
# Intentionally the secretsmanager group ONLY — ExternalSecrets
# (external-secrets.io) are NEVER swept here (ESO owns their lifecycle).
ASM_MR_RESOURCE="secrets.secretsmanager.aws.m.upbound.io"

# asm_cleanup_targets — print the AWS secret names to delete, one per line.
#
# Enumerates ONLY ASM Secret MRs and reads each MR's spec.forProvider.name
# (the literal AWS secret name the provider manages). Blank names (MRs not
# yet reconciled, so .name is unset) are dropped so we never feed an empty
# --secret-id downstream. Returns kubectl's exit code on failure so callers
# can distinguish "cluster unreachable" from "no MRs".
asm_cleanup_targets() {
  local raw rc
  raw="$(kubectl get "$ASM_MR_RESOURCE" -A \
    -o jsonpath='{range .items[*]}{.spec.forProvider.name}{"\n"}{end}')"
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  # Drop blank lines (unset names). awk 'NF' keeps only non-empty records.
  printf '%s\n' "$raw" | awk 'NF'
}

# asm_delete_one <name> — delete a single ASM secret, best-effort.
#
# --force-delete-without-recovery matches the Composition's
# recoveryWindowInDays:0 (these are ephemeral test secrets). Refuses an empty
# id (deleting an empty/wildcard secret-id is a footgun). A delete failure
# (already gone / ResourceNotFound / transient) is NON-fatal: it WARNs and
# returns 0, because this runs in a best-effort cleanup trap and must not
# abort the rest of the sweep.
asm_delete_one() {
  local name="$1"
  if [ -z "$name" ]; then
    echo "    WARN: refusing to delete empty secret id" >&2
    return 0
  fi
  if aws secretsmanager delete-secret \
       --secret-id "$name" \
       --force-delete-without-recovery \
       --output text >/dev/null 2>&1; then
    echo "    deleted: $name"
  else
    echo "    WARN: could not delete $name (already gone or API error)"
  fi
  return 0
}

# asm_cleanup_run — enumerate ASM secret MRs from the live cluster and delete
# each from AWS. Best-effort: a failure to enumerate (cluster already gone)
# WARNs loudly (so it is visible in CI logs and NOT confused with a clean
# run) and returns 0. Always safe to call from a trap.
asm_cleanup_run() {
  local names rc name n=0
  names="$(asm_cleanup_targets)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "    WARN: could not enumerate ${ASM_MR_RESOURCE} (kubectl rc=$rc) —" \
         "ASM secrets may leak; sweep them manually" >&2
    return 0
  fi
  if [ -z "$names" ]; then
    echo "    (no ASM Secret MRs in cluster — nothing to sweep)"
    return 0
  fi
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    asm_delete_one "$name"
    n=$((n + 1))
  done <<EOF
$names
EOF
  echo "    swept $n ASM secret(s) by MR enumeration"
  return 0
}
