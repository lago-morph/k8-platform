#!/usr/bin/env bash
# instantiate-lib.sh — the parametrized hermetic instantiate-and-verify harness
# for the LIVE behavioral suite (FINAL-PLAN §P4; ADR-0006).
#
# WHAT THIS IS. The `after` tier proves a resource the platform ALREADY
# provisioned is real+healthy (it selects by the Composition's crossplane-kind
# tag — see tests/live/checks/after/*-live.sh). This library is the rigorous
# complement: it CREATES a fresh resource by driving the REAL Crossplane
# controller (under its own IRSA identity — NOT an admin-AWS write), waits for
# the controller to converge it (Synced=True + Ready=True), REUSES an after-tier
# verify oracle to prove the real AWS resource exists+healthy, and then ALWAYS
# deletes it (trap-based) and waits for the delete to settle. It emits
# `covers <kind>` only on a verified success.
#
# WHY DRIVE THE CONTROLLER, NOT AWS DIRECTLY. The thing under test is the
# Crossplane abstraction end-to-end: manifest -> controller -> IRSA -> real AWS
# resource. An admin-AWS `aws iam create-role` would prove nothing about the
# platform. So the create path is `kubectl apply` of a managed resource against
# the hub, relayed through scripts/sandbox-kubeconfig.sh; the controller's own
# scoped IRSA (terraform/management/irsa.tf) performs the AWS write. If the
# resource is mis-named for those scoped perms the controller create fails
# CLOSED — which is exactly the contract this harness exercises.
#
# FAIL-CLOSED. The create path runs ONLY in LIVE_MODE=mutating. Unset/garbage
# LIVE_MODE degrades to readonly (live-lib.sh live_mode()), and in readonly this
# harness SKIPs (exit 2) WITHOUT applying anything. Mutating is OFF by default.
#
# REAPER CONTRACT (FINAL-PLAN §8). Every created resource carries the reaper's
# two required tags so a leaked resource (e.g. a killed run) is reclaimable by
# the P3 reaper, never orphaned:
#     live-verify=<RUN_ID>                  (the run-id the reaper deletes tag-conditioned on)
#     live-verify-created=<epoch-seconds>   (the age the reaper's age-floor compares against)
# A resource missing EITHER tag is fail-safe-protected by reaper-select.sh
# forever, so emitting both is mandatory, not cosmetic.
#
# This file holds ONLY the parametrized engine; the two concrete checks
# (tests/live/checks/instantiate/{iam-role,secretsmanager-secret}-instantiate.sh)
# supply a <kind>, a manifest-renderer fn, and a verify fn.

set -uo pipefail

_IV_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_IV_REPO_ROOT="$(cd "$_IV_LIB_DIR/../../.." && pwd)"

# Reuse the live exit-code contract + the integration helpers (wait_for, log,
# ok, ng, skip()->exit2, covers, live_mode). No fork (DevX-r2 m4).
# shellcheck source=/dev/null
. "$_IV_LIB_DIR/live-lib.sh"

# ---- relay seam ----------------------------------------------------------
# Production drives kubectl against the hub through the SSM relay helper
# (scripts/sandbox-kubeconfig.sh -c <cluster> --exec kubectl ...). The hermetic
# unit test sets IV_DIRECT_KUBECTL=1 and puts a FAKE kubectl on PATH, so the
# engine is exercised with NO cluster and NO AWS. Both paths flow through this
# one wrapper so the production code under test is the very code that ships.
IV_RELAY="${IV_RELAY:-$_IV_REPO_ROOT/scripts/sandbox-kubeconfig.sh}"
IV_CLUSTER="${IV_CLUSTER:-k8-platform-mgmt}"
IV_DIRECT_KUBECTL="${IV_DIRECT_KUBECTL:-0}"

_iv_kubectl() {
  if [ "$IV_DIRECT_KUBECTL" = "1" ]; then
    kubectl "$@"
  else
    "$IV_RELAY" -c "$IV_CLUSTER" --exec kubectl "$@"
  fi
}

# ---- shared tag/name constants -------------------------------------------
# The reaper's required tag KEYS (values are per-run). Centralized so the
# concrete checks and the unit test reference one source.
IV_TAG_RUNID_KEY="live-verify"
IV_TAG_CREATED_KEY="live-verify-created"
export IV_TAG_RUNID_KEY IV_TAG_CREATED_KEY

# iv_created_epoch — the live-verify-created tag value (epoch seconds). A seam so
# the unit test can pin it deterministically.
iv_created_epoch() { echo "${IV_FAKE_EPOCH:-$(date +%s)}"; }

# ---- convergence + delete settle bounds ----------------------------------
# Crossplane create+converge of a real AWS resource is bounded but not instant;
# ≥300s per the brief. Overridable (the unit test drops them to 0 — its fake
# kubectl reports Ready immediately, so no real waiting happens).
IV_CONVERGE_TIMEOUT="${IV_CONVERGE_TIMEOUT:-300}"
IV_CONVERGE_INTERVAL="${IV_CONVERGE_INTERVAL:-10}"
IV_DELETE_TIMEOUT="${IV_DELETE_TIMEOUT:-300}"
IV_DELETE_INTERVAL="${IV_DELETE_INTERVAL:-10}"

# _iv_condition_true <type> <kind> <name> — true iff the MR's <type> condition
# (Synced|Ready) is status True. Read-only get of a jsonpath; no secret material.
_iv_condition_true() {
  local ctype="$1" kind="$2" name="$3" got
  got="$(_iv_kubectl get "$kind" "$name" \
    -o "jsonpath={.status.conditions[?(@.type=='$ctype')].status}" 2>/dev/null)" || return 1
  [ "$got" = "True" ]
}

# _iv_absent <kind> <name> — true once the MR no longer exists (delete settled).
_iv_absent() {
  local kind="$1" name="$2"
  ! _iv_kubectl get "$kind" "$name" >/dev/null 2>&1
}

# instantiate_and_verify <kind> <manifest_renderer_fn> <verify_fn> [mr_kind] [mr_name]
#
#   <kind>                 the group/Kind this check covers (for covers()), e.g.
#                          iam.aws.m.upbound.io/Role.
#   <manifest_renderer_fn> a fn that PRINTS the full MR manifest to stdout. It is
#                          handed ($1) the RUN_ID and ($2) the created-epoch so it
#                          can stamp the per-run name + the two reaper tags. It
#                          must NOT apply anything (the engine owns apply/delete).
#   <verify_fn>            a fn that proves the real AWS resource exists+healthy,
#                          selected by tag (REUSE the after-tier oracle). Handed
#                          ($1) the RUN_ID. Returns 0 on healthy, non-zero else.
#   [mr_kind]              the kubectl kind/name the engine polls + deletes,
#   [mr_name]              e.g. "secret.secretsmanager.aws.m.upbound.io" + the
#                          per-run metadata.name. Defaults are derived below.
#
# Control flow (fail-closed, always-cleanup):
#   1. mutating-gate         readonly => skip (exit 2), NOTHING applied.
#   2. relay/tooling precond not-applicable => skip.
#   3. render + apply        render the manifest, kubectl apply via the relay,
#                            REGISTER the delete in a trap BEFORE waiting.
#   4. converge              wait_for Synced=True AND Ready=True (≥300s).
#   5. verify                run verify_fn (real AWS resource, by tag).
#   6. cleanup (always)      the trap deletes + waits for absence on EVERY exit
#                            path — success, verify-fail, or convergence-timeout.
#   7. covers                emit covers <kind> + exit 0 ONLY on verified success.
instantiate_and_verify() {
  local kind="$1" render_fn="$2" verify_fn="$3"
  local mr_kind="${4:-}" mr_name="${5:-}"

  # 1. FAIL-CLOSED mutating gate — readonly SKIPs without applying anything.
  if [ "$(live_mode)" != "mutating" ]; then
    skip "LIVE_MODE!=mutating — instantiate-and-verify of $kind is a create-path; readonly degrades to safe (nothing applied)"
  fi

  # 2. Preconditions — the relay + kubectl must be exercisable here; otherwise
  #    not-applicable (skip), not a failure. In direct mode only kubectl matters.
  command -v kubectl >/dev/null 2>&1 || skip "kubectl not on PATH ($kind instantiate not exercisable here)"
  if [ "$IV_DIRECT_KUBECTL" != "1" ]; then
    [ -x "$IV_RELAY" ] || skip "relay $IV_RELAY not executable ($kind instantiate not exercisable here)"
  fi

  local run_id="${RUN_ID:?RUN_ID must be set}"
  local epoch; epoch="$(iv_created_epoch)"

  # 3. Render the manifest (renderer stamps name + the two reaper tags).
  local manifest; manifest="$("$render_fn" "$run_id" "$epoch")" \
    || { ng "$kind manifest renderer failed"; return 1; }

  # Derive what we poll/delete from the rendered manifest unless the caller
  # passed them explicitly (kept overridable so the unit test can pin them).
  if [ -z "$mr_kind" ]; then
    mr_kind="$(printf '%s\n' "$manifest" | sed -n 's/^kind:[[:space:]]*//p' | head -n1)"
  fi
  if [ -z "$mr_name" ]; then
    mr_name="$(printf '%s\n' "$manifest" | sed -n 's/^[[:space:]]*name:[[:space:]]*//p' | head -n1)"
  fi
  [ -n "$mr_kind" ] && [ -n "$mr_name" ] \
    || { ng "$kind could not derive MR kind/name from the rendered manifest"; return 1; }

  log "instantiating $kind as $mr_kind/$mr_name (RUN_ID=$run_id, ${IV_TAG_CREATED_KEY}=$epoch)"

  # Register cleanup BEFORE the apply so a crash mid-converge still deletes.
  # The integration lib's run_cleanup trap (EXIT) drains CLEANUP_CMDS; we append
  # a delete that tolerates an already-gone object (--ignore-not-found). The
  # closure re-declares _iv_kubectl + its env so the trap (eval'd in a clean
  # subshell context) routes through the same relay/direct seam.
  add_cleanup "$(declare -f _iv_kubectl); IV_DIRECT_KUBECTL='$IV_DIRECT_KUBECTL' IV_RELAY='$IV_RELAY' IV_CLUSTER='$IV_CLUSTER' _iv_kubectl delete '$mr_kind' '$mr_name' --ignore-not-found --wait=false"

  # Apply via the relay (the REAL controller picks it up under its IRSA).
  if ! printf '%s\n' "$manifest" | _iv_kubectl apply -f - >/dev/null 2>&1; then
    ng "$kind: kubectl apply of $mr_kind/$mr_name failed (controller/relay rejected the create)"
    return 1
  fi

  # 4. Converge — bounded poll for BOTH Synced=True and Ready=True (≥300s).
  if ! wait_for "$kind $mr_name Synced=True" "$IV_CONVERGE_TIMEOUT" "$IV_CONVERGE_INTERVAL" \
        -- _iv_condition_true Synced "$mr_kind" "$mr_name"; then
    ng "$kind: $mr_name never reached Synced=True within ${IV_CONVERGE_TIMEOUT}s (controller did not converge the create)"
    return 1
  fi
  if ! wait_for "$kind $mr_name Ready=True" "$IV_CONVERGE_TIMEOUT" "$IV_CONVERGE_INTERVAL" \
        -- _iv_condition_true Ready "$mr_kind" "$mr_name"; then
    ng "$kind: $mr_name never reached Ready=True within ${IV_CONVERGE_TIMEOUT}s"
    return 1
  fi

  # 5. Verify the REAL AWS resource exists+healthy, selected by tag (reuse the
  #    after-tier oracle). verify_fn owns its own AWS preconditions.
  if ! "$verify_fn" "$run_id"; then
    ng "$kind: converged in-cluster but the real AWS resource did not verify (by tag live-verify=$run_id)"
    return 1
  fi

  ok "$kind instantiated, converged (Synced+Ready), and the real AWS resource verified by tag"

  # 6. Cleanup is the registered trap; additionally issue the delete + wait for
  #    it to settle now so a PASS leaves the account clean (best-effort — the
  #    trap already guarantees the delete is ISSUED on every path).
  _iv_kubectl delete "$mr_kind" "$mr_name" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  wait_for "$kind $mr_name deletion settled" "$IV_DELETE_TIMEOUT" "$IV_DELETE_INTERVAL" \
    -- _iv_absent "$mr_kind" "$mr_name" || \
    note "$kind: $mr_name delete issued but not yet observed absent (reaper-protected via tags)"

  # 7. covers ONLY on verified success.
  covers "$kind"
  exit "$LIVE_RC_PASS"
}
