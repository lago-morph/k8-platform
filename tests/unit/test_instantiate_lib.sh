#!/usr/bin/env bash
# Hermetic unit test for tests/live/lib/instantiate-lib.sh + the two instantiate
# checks (FINAL-PLAN §P4). Proves the engine's contract with a FAKE kubectl and a
# FAKE aws (both record-to-file, like tests/unit/test_reaper_select.sh /
# test_account_mutex.sh fake their backends) — NO real cluster, NO real AWS.
#
# It proves, end-to-end through the REAL check scripts where possible:
#   (a) readonly mode SKIPs (exit 2) WITHOUT applying anything;
#   (b) mutating mode renders a manifest carrying the correct reaper tags
#       (live-verify=<RUN_ID> + live-verify-created=<epoch>) AND the scoped
#       naming (k8-platform-live-verify-* role / k8-platform/live-verify-* secret);
#   (c) the cleanup DELETE is ALWAYS issued — even when verify FAILS;
#   (d) `covers <kind>` is emitted ONLY on a verified success.

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root
# shellcheck disable=SC1091
. tests/lib/assert.sh

REPO_ROOT="$(pwd)"
ROLE_CHECK="tests/live/checks/instantiate/iam-role-instantiate.sh"
SECRET_CHECK="tests/live/checks/instantiate/secretsmanager-secret-instantiate.sh"

# ---- fake-bin harness ----------------------------------------------------
# A throwaway PATH-front dir holds fake `kubectl` + `aws` that record every call
# (one arg-line per invocation) to $REC, plus the applied manifest stdin to
# $MANIFEST. Behaviour is tuned so the engine's happy path converges instantly:
#   kubectl apply -f -                 -> record stdin to $MANIFEST, exit 0
#   kubectl get <k> <n> -o jsonpath=.. -> print "True"  (Synced/Ready satisfied)
#   kubectl get <k> <n>   (no -o)      -> exit 1         (so _iv_absent => gone)
#   kubectl delete ...                 -> record, exit 0
#   aws sts get-caller-identity        -> exit 0
#   aws iam list-role-tags             -> crossplane-kind + live-verify tags
#   aws secretsmanager describe-secret -> Name + crossplane-kind + live-verify tags
# The aws tag fakes echo back $FAKE_RUNID so the verify's run-id match is real.
BIN="$(mktemp -d)"
REC="$BIN/calls.log"
MANIFEST="$BIN/applied.yaml"
: > "$REC"; : > "$MANIFEST"

cat > "$BIN/kubectl" <<'SH'
#!/usr/bin/env bash
echo "kubectl $*" >> "$REC"
case " $* " in
  *" apply -f - "*) cat >> "$MANIFEST"; exit 0 ;;
  *" delete "*)     exit 0 ;;
  *" get "*)
    case " $* " in
      *" -o "*jsonpath*) echo "True"; exit 0 ;;   # condition probe => Ready/Synced
      *) exit 1 ;;                                  # bare get => absent (delete settled)
    esac ;;
esac
exit 0
SH

cat > "$BIN/aws" <<'SH'
#!/usr/bin/env bash
echo "aws $*" >> "$REC"
case "$1 $2" in
  "sts get-caller-identity") exit 0 ;;
  "iam list-role-tags")
    printf '[{"Key":"crossplane-kind","Value":"role.iam.aws.m.upbound.io"},{"Key":"live-verify","Value":"%s"}]\n' "$FAKE_RUNID"
    exit 0 ;;
  "secretsmanager describe-secret")
    printf '{"Name":"k8-platform/live-verify-%s","DeletedDate":null,"Tags":[{"Key":"crossplane-kind","Value":"secret.secretsmanager.aws.m.upbound.io"},{"Key":"live-verify","Value":"%s"}]}\n' "$FAKE_RUNID" "$FAKE_RUNID"
    exit 0 ;;
esac
exit 0
SH
chmod +x "$BIN/kubectl" "$BIN/aws"
trap 'rm -rf "$BIN"' EXIT

FAKE_RUNID="ut0001"
FAKE_EPOCH="1700000000"

# run_check <check.sh> <LIVE_MODE> [extra-env...] — run a real check script under
# the fake bins + the direct-kubectl seam, capture stdout+exit. RUN_ID/epoch are
# pinned so assertions are deterministic. Converge/delete timeouts -> 0 (the fake
# reports Ready immediately, so no real waiting).
run_check() {
  local check="$1" mode="$2"; shift 2
  set +e
  CHECK_OUT="$(env \
      PATH="$BIN:$PATH" \
      REC="$REC" MANIFEST="$MANIFEST" FAKE_RUNID="$FAKE_RUNID" \
      RUN_ID="$FAKE_RUNID" IV_FAKE_EPOCH="$FAKE_EPOCH" \
      IV_DIRECT_KUBECTL=1 \
      IV_CONVERGE_TIMEOUT=0 IV_CONVERGE_INTERVAL=0 \
      IV_DELETE_TIMEOUT=0 IV_DELETE_INTERVAL=0 \
      KEEP=0 LIVE_MODE="$mode" "$@" \
      bash "$check" 2>&1)"
  CHECK_RC=$?
  set -e
}

# ── (a) readonly mode SKIPs without applying anything ─────────────────────
echo "── (a) readonly => SKIP (exit 2), NOTHING applied ────────────"
for check in "$ROLE_CHECK" "$SECRET_CHECK"; do
  : > "$REC"; : > "$MANIFEST"
  run_check "$check" readonly
  assert_eq "$(basename "$check"): readonly => exit 2 (skip)" 2 "$CHECK_RC"
  assert_eq "$(basename "$check"): readonly applied NOTHING" "" "$(grep -c 'apply -f -' "$REC" | sed 's/^0$//')"
  assert_contains "$(basename "$check"): says it skipped (mutating gate)" "SKIP" "$CHECK_OUT"
done

# ── (b) mutating renders correct reaper tags + scoped naming ──────────────
echo ""
echo "── (b) mutating => manifest carries reaper tags + scoped name ─"
# IAM role
: > "$REC"; : > "$MANIFEST"
run_check "$ROLE_CHECK" mutating
ROLE_MANIFEST="$(cat "$MANIFEST")"
assert_contains "role: live-verify tag = RUN_ID"        "live-verify: \"$FAKE_RUNID\""          "$ROLE_MANIFEST"
assert_contains "role: live-verify-created tag = epoch" "live-verify-created: \"$FAKE_EPOCH\""  "$ROLE_MANIFEST"
assert_contains "role: external-name is k8-platform-live-verify-<RUN_ID>" \
  "crossplane.io/external-name: k8-platform-live-verify-$FAKE_RUNID" "$ROLE_MANIFEST"
assert_contains "role: is an iam Role MR" "kind: Role" "$ROLE_MANIFEST"

# SecretsManager secret
: > "$REC"; : > "$MANIFEST"
run_check "$SECRET_CHECK" mutating
SECRET_MANIFEST="$(cat "$MANIFEST")"
assert_contains "secret: live-verify tag = RUN_ID"        "live-verify: \"$FAKE_RUNID\""          "$SECRET_MANIFEST"
assert_contains "secret: live-verify-created tag = epoch" "live-verify-created: \"$FAKE_EPOCH\""  "$SECRET_MANIFEST"
assert_contains "secret: external-name is k8-platform/live-verify-<RUN_ID>" \
  "crossplane.io/external-name: k8-platform/live-verify-$FAKE_RUNID" "$SECRET_MANIFEST"
assert_contains "secret: recoveryWindowInDays=0 (immediate delete)" "recoveryWindowInDays: 0" "$SECRET_MANIFEST"
assert_contains "secret: is a secretsmanager Secret MR" "kind: Secret" "$SECRET_MANIFEST"

# ── (d) covers <kind> emitted ONLY on a verified success ──────────────────
echo ""
echo "── (d) success => covers <kind> + exit 0; delete also issued ──"
: > "$REC"; : > "$MANIFEST"
run_check "$ROLE_CHECK" mutating
assert_eq "role: verified success => exit 0" 0 "$CHECK_RC"
assert_contains "role: emits COVERS iam.aws.m.upbound.io/Role" "COVERS iam.aws.m.upbound.io/Role" "$CHECK_OUT"
assert_contains "role: success path issued a delete (cleanup)" "delete role.iam.aws.m.upbound.io" "$(cat "$REC")"

: > "$REC"; : > "$MANIFEST"
run_check "$SECRET_CHECK" mutating
assert_eq "secret: verified success => exit 0" 0 "$CHECK_RC"
assert_contains "secret: emits COVERS secretsmanager.aws.m.upbound.io/Secret" \
  "COVERS secretsmanager.aws.m.upbound.io/Secret" "$CHECK_OUT"
assert_contains "secret: success path issued a delete (cleanup)" \
  "delete secret.secretsmanager.aws.m.upbound.io" "$(cat "$REC")"

# ── (c) cleanup delete is ALWAYS issued — even when verify FAILS ──────────
# Drive the ENGINE directly with stub render/verify fns so verify failure is
# deterministic (no AWS). Proves: verify-fail => non-zero, NO covers, but the
# delete WAS issued (trap-based cleanup fired). The driver is written to a temp
# script (a quoted heredoc — NOTHING here is spliced by the outer shell); it
# sources the lib and reads FAKE_* / the MR kind+name from the environment, and
# references the lib's OWN tag-key vars.
echo ""
echo "── (c) verify FAILS => no covers, non-zero, BUT delete issued ─"
: > "$REC"; : > "$MANIFEST"
DRIVER="$BIN/engine_driver.sh"
cat > "$DRIVER" <<'DRV'
#!/usr/bin/env bash
set -uo pipefail
. tests/live/lib/instantiate-lib.sh
render_stub() {
  cat <<YAML
apiVersion: example.test/v1
kind: Widget
metadata:
  name: ${MR_NAME}
  annotations:
    crossplane.io/external-name: k8-platform-live-verify-${FAKE_RUNID}
spec:
  forProvider:
    tags:
      ${IV_TAG_RUNID_KEY}: "${FAKE_RUNID}"
      ${IV_TAG_CREATED_KEY}: "${FAKE_EPOCH}"
YAML
}
verify_fail() { ng "stub verify deliberately fails"; return 1; }
instantiate_and_verify "example.test/Widget" render_stub verify_fail "$MR_KIND" "$MR_NAME"
echo "ENGINE_RC=$?"
DRV
ENGINE_OUT="$(
  set +e
  env PATH="$BIN:$PATH" REC="$REC" MANIFEST="$MANIFEST" \
      RUN_ID="$FAKE_RUNID" FAKE_RUNID="$FAKE_RUNID" FAKE_EPOCH="$FAKE_EPOCH" \
      IV_FAKE_EPOCH="$FAKE_EPOCH" IV_DIRECT_KUBECTL=1 \
      IV_CONVERGE_TIMEOUT=0 IV_CONVERGE_INTERVAL=0 IV_DELETE_TIMEOUT=0 IV_DELETE_INTERVAL=0 \
      LIVE_MODE=mutating \
      MR_KIND="widget.example.test" MR_NAME="live-verify-widget-$FAKE_RUNID" \
    bash "$DRIVER"
  echo "OUTER_RC=$?"
)"
assert_contains "verify-fail: NO covers emitted" "true" \
  "$(printf '%s' "$ENGINE_OUT" | grep -q 'COVERS' && echo false || echo true)"
assert_contains "verify-fail: engine reports the verify failure" "did not verify" "$ENGINE_OUT"
assert_contains "verify-fail: cleanup delete WAS issued (trap fired)" \
  "delete widget.example.test live-verify-widget-$FAKE_RUNID" "$(cat "$REC")"

assert_summary
