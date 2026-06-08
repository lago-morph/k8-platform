#!/usr/bin/env bash
# Hermetic unit test for the P5 guard-fired negative checks
# (tests/live/checks/negative/*.sh).
#
# Proves each negative check without a real cluster by:
#   - building a minimal fake-REPO_ROOT tree so the checks resolve
#     their REPO_ROOT correctly and find a fake scripts/sandbox-kubeconfig.sh
#   - injecting a fake kubectl (reads stdin for apply -f -, scripted responses)
#   - faking aws CLI calls (sts, ec2) so preconditions pass
#
# For each of the three negatives, asserts all four required properties:
#   (a) skips in readonly (LIVE_MODE=readonly)
#   (b) passes when the fake denies with the MATCHING reason (guard fired)
#   (c) FAILS when the fake ALLOWS the forbidden action (guard didn't fire)
#   (d) FAILS when denied for the WRONG reason
#
# No real cluster, no AWS, no network. Pure bash.

set -uo pipefail
REAL_REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REAL_REPO_ROOT"

. tests/lib/assert.sh

# ──────────────────────────────────────────────────────────────────────────────
# Test infrastructure
# ──────────────────────────────────────────────────────────────────────────────

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# Build a fake REPO_ROOT.  The check scripts resolve REPO_ROOT as
#   $(cd "$HERE/../../../.." && pwd)
# where HERE is the directory containing the script.  We copy the checks
# into a parallel fake tree so REPO_ROOT resolves to $FAKE_ROOT.
FAKE_ROOT="$WORKDIR/repo"
mkdir -p "$FAKE_ROOT/tests/live/checks/negative"
mkdir -p "$FAKE_ROOT/tests/live/lib"
mkdir -p "$FAKE_ROOT/tests/integration/lib"
mkdir -p "$FAKE_ROOT/scripts"

ln -s "$REAL_REPO_ROOT/tests/live/lib/live-lib.sh" \
      "$FAKE_ROOT/tests/live/lib/live-lib.sh"
ln -s "$REAL_REPO_ROOT/tests/integration/lib/test-lib.sh" \
      "$FAKE_ROOT/tests/integration/lib/test-lib.sh"
ln -s "$REAL_REPO_ROOT/tests/lib" "$FAKE_ROOT/tests/lib"

for f in argocd-appproject-sourcerepo-guard.sh \
          argocd-appproject-destination-guard.sh \
          rbac-crossplane-scope-guard.sh; do
  cp "$REAL_REPO_ROOT/tests/live/checks/negative/$f" \
     "$FAKE_ROOT/tests/live/checks/negative/$f"
done

# ---- fake helper binaries -----------------------------------------------

mkdir -p "$WORKDIR/bin"

# fake aws: sts -> success; ec2 describe-instances -> relay ID.
cat > "$WORKDIR/bin/aws" <<'AWSEOF'
#!/usr/bin/env bash
case "$*" in
  *get-caller-identity*)
    printf '{"Account":"123456789012","UserId":"AIDATEST","Arn":"arn:aws:iam::123456789012:user/test"}\n'
    exit 0 ;;
  *describe-instances*)
    printf 'i-0deadbeef001\n'
    exit 0 ;;
  *) exit 0 ;;
esac
AWSEOF
chmod +x "$WORKDIR/bin/aws"

# fake session-manager-plugin — just needs to be on PATH.
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORKDIR/bin/session-manager-plugin"
chmod +x "$WORKDIR/bin/session-manager-plugin"

# fake sandbox-kubeconfig.sh: strips relay flags, execs the --exec command.
# stdin is passed through (critical for `kubectl apply -f -` heredocs).
cat > "$FAKE_ROOT/scripts/sandbox-kubeconfig.sh" <<'HELPEREOF'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
  case "$1" in
    -c|--cluster|-r|--region|-p|--port) shift 2 ;;
    --exec) shift; exec "$@" ;;
    *) shift ;;
  esac
done
exit 0
HELPEREOF
chmod +x "$FAKE_ROOT/scripts/sandbox-kubeconfig.sh"

# ---- write_kubectl <script-body> — install a fresh fake kubectl ------------
# NOTE: when the check uses `kubectl apply -f -`, the manifest YAML is passed
# on stdin.  The fake kubectl reads stdin to determine the app name so it can
# give the right scripted response.
write_kubectl() {
  printf '#!/usr/bin/env bash\n%s\n' "$1" > "$WORKDIR/bin/kubectl"
  chmod +x "$WORKDIR/bin/kubectl"
}

# ---- run_check_rc <check-name> <env-pairs...> ------------------------------
run_check_rc() {
  local name="$1"; shift
  set +e
  env \
    PATH="$WORKDIR/bin:$PATH" \
    LIVE_CLUSTER="k8-platform-mgmt" \
    AWS_REGION="us-east-1" \
    RUN_ID="testrun001" \
    "$@" \
    bash "$FAKE_ROOT/tests/live/checks/negative/$name" >/dev/null 2>&1
  local rc=$?
  set -e
  echo "$rc"
}

LIVE_RC_SKIP=2
LIVE_RC_PASS=0

# Reduce poll iterations to 1 (× 2s = 2s max per poll-driven case) to keep the
# unit test fast.  The checks default to 10 iterations on real clusters.
POLL_OVERRIDE="LIVE_NEG_POLL_ITERS=1"

# ═══════════════════════════════════════════════════════════════════════════════
# Check 1: argocd-appproject-sourcerepo-guard.sh
# ═══════════════════════════════════════════════════════════════════════════════
SRCREPO="argocd-appproject-sourcerepo-guard.sh"

echo "── sourcerepo: (a) skips in readonly ─────────────────────────────────"
assert_eq "sourcerepo: LIVE_MODE=readonly => skip (2)" \
  "$LIVE_RC_SKIP" \
  "$(run_check_rc "$SRCREPO" LIVE_MODE=readonly $POLL_OVERRIDE)"

echo ""
echo "── sourcerepo: (b) PASSES when guard fires with matching reason ───────"
# apply -f - reads stdin; check for deny/allow app name in stdin content.
write_kubectl '
CMD="$*"
case "$CMD" in
  "get ns argocd")
    echo "argocd   Active"; exit 0 ;;
  "get appproject k8-platform -n argocd -o json")
    printf '"'"'{"spec":{"sourceRepos":["https://github.com/lago-morph/k8-platform.git"]}}\n'"'"'
    exit 0 ;;
  "get appproject k8-platform -n argocd")
    echo "k8-platform   project.argoproj.io"; exit 0 ;;
  "apply -f -")
    content="$(cat)"
    if printf "%s" "$content" | grep -q "live-neg-appproj-deny"; then
      echo "error: application repo https://github.com/attacker/evil-charts.git is not permitted in project k8-platform"
      exit 1
    fi
    echo "application.argoproj.io created"; exit 0 ;;
  delete*|*"--ignore-not-found"*) exit 0 ;;
  *) exit 0 ;;
esac
'
assert_eq "sourcerepo: guard fires with matching reason => pass (0)" \
  "$LIVE_RC_PASS" \
  "$(run_check_rc "$SRCREPO" LIVE_MODE=mutating $POLL_OVERRIDE)"

echo ""
echo "── sourcerepo: (c) FAILS when guard does NOT fire ────────────────────"
# apply always succeeds (guard did not fire); get application returns no conditions.
write_kubectl '
CMD="$*"
case "$CMD" in
  "get ns argocd") echo "argocd   Active"; exit 0 ;;
  "get appproject k8-platform -n argocd -o json")
    printf '"'"'{"spec":{"sourceRepos":["https://github.com/lago-morph/k8-platform.git"]}}\n'"'"'
    exit 0 ;;
  "get appproject k8-platform -n argocd") echo "k8-platform"; exit 0 ;;
  "apply -f -")
    cat >/dev/null   # drain stdin
    echo "application.argoproj.io created"; exit 0 ;;
  *"-o json"*)
    echo "{\"status\":{\"conditions\":[]}}"; exit 0 ;;
  delete*|*"--ignore-not-found"*) exit 0 ;;
  *) exit 0 ;;
esac
'
rc="$(run_check_rc "$SRCREPO" LIVE_MODE=mutating $POLL_OVERRIDE)"
if [ "$rc" -ne 0 ] && [ "$rc" -ne "$LIVE_RC_SKIP" ]; then
  _pass "sourcerepo: guard did not fire => FAIL (non-zero exit $rc)"
else
  _fail "sourcerepo: guard did not fire should produce FAIL" \
    "got exit $rc (expected non-zero, non-skip)"
fi

echo ""
echo "── sourcerepo: (d) FAILS when denied for the WRONG reason ───────────"
# apply returns an error, but NOT the "not permitted" guard message.
write_kubectl '
CMD="$*"
case "$CMD" in
  "get ns argocd") echo "argocd   Active"; exit 0 ;;
  "get appproject k8-platform -n argocd -o json")
    printf '"'"'{"spec":{"sourceRepos":["https://github.com/lago-morph/k8-platform.git"]}}\n'"'"'
    exit 0 ;;
  "get appproject k8-platform -n argocd") echo "k8-platform"; exit 0 ;;
  "apply -f -")
    content="$(cat)"
    if printf "%s" "$content" | grep -q "live-neg-appproj-deny"; then
      echo "error: the server is currently unable to handle the request"
      exit 1
    fi
    echo "application.argoproj.io created"; exit 0 ;;
  delete*|*"--ignore-not-found"*) exit 0 ;;
  *) exit 0 ;;
esac
'
rc="$(run_check_rc "$SRCREPO" LIVE_MODE=mutating $POLL_OVERRIDE)"
if [ "$rc" -ne 0 ] && [ "$rc" -ne "$LIVE_RC_SKIP" ]; then
  _pass "sourcerepo: wrong denial reason => FAIL (non-zero exit $rc)"
else
  _fail "sourcerepo: wrong denial reason should produce FAIL" \
    "got exit $rc (expected non-zero non-skip)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Check 2: argocd-appproject-destination-guard.sh
# ═══════════════════════════════════════════════════════════════════════════════
DESTGUARD="argocd-appproject-destination-guard.sh"

echo ""
echo "── destination: (a) skips in readonly ───────────────────────────────"
assert_eq "destination: LIVE_MODE=readonly => skip (2)" \
  "$LIVE_RC_SKIP" \
  "$(run_check_rc "$DESTGUARD" LIVE_MODE=readonly $POLL_OVERRIDE)"

echo ""
echo "── destination: (b) PASSES when guard fires with matching reason ─────"
write_kubectl '
CMD="$*"
case "$CMD" in
  "get ns argocd") echo "argocd   Active"; exit 0 ;;
  "get appproject platform-spoke -n argocd -o json")
    printf '"'"'{"spec":{"sourceRepos":["https://github.com/lago-morph/k8-platform.git"]}}\n'"'"'
    exit 0 ;;
  "get appproject platform-spoke -n argocd") echo "platform-spoke   project.argoproj.io"; exit 0 ;;
  "apply -f -")
    content="$(cat)"
    if printf "%s" "$content" | grep -q "live-neg-dest-deny"; then
      echo "error: destination {server:https://kubernetes.default.svc ns:default} is not permitted in project platform-spoke"
      exit 1
    fi
    echo "application.argoproj.io created"; exit 0 ;;
  delete*|*"--ignore-not-found"*) exit 0 ;;
  *) exit 0 ;;
esac
'
assert_eq "destination: guard fires with matching reason => pass (0)" \
  "$LIVE_RC_PASS" \
  "$(run_check_rc "$DESTGUARD" LIVE_MODE=mutating $POLL_OVERRIDE)"

echo ""
echo "── destination: (c) FAILS when guard does NOT fire ──────────────────"
write_kubectl '
CMD="$*"
case "$CMD" in
  "get ns argocd") echo "argocd   Active"; exit 0 ;;
  "get appproject platform-spoke -n argocd -o json")
    printf '"'"'{"spec":{"sourceRepos":["https://github.com/lago-morph/k8-platform.git"]}}\n'"'"'
    exit 0 ;;
  "get appproject platform-spoke -n argocd") echo "platform-spoke"; exit 0 ;;
  "apply -f -")
    cat >/dev/null
    echo "application.argoproj.io created"; exit 0 ;;
  *"-o json"*)
    echo "{\"status\":{\"conditions\":[]}}"; exit 0 ;;
  delete*|*"--ignore-not-found"*) exit 0 ;;
  *) exit 0 ;;
esac
'
rc="$(run_check_rc "$DESTGUARD" LIVE_MODE=mutating $POLL_OVERRIDE)"
if [ "$rc" -ne 0 ] && [ "$rc" -ne "$LIVE_RC_SKIP" ]; then
  _pass "destination: guard did not fire => FAIL (non-zero exit $rc)"
else
  _fail "destination: guard did not fire should produce FAIL" \
    "got exit $rc (expected non-zero non-skip)"
fi

echo ""
echo "── destination: (d) FAILS when denied for the WRONG reason ──────────"
write_kubectl '
CMD="$*"
case "$CMD" in
  "get ns argocd") echo "argocd   Active"; exit 0 ;;
  "get appproject platform-spoke -n argocd -o json")
    printf '"'"'{"spec":{"sourceRepos":["https://github.com/lago-morph/k8-platform.git"]}}\n'"'"'
    exit 0 ;;
  "get appproject platform-spoke -n argocd") echo "platform-spoke"; exit 0 ;;
  "apply -f -")
    content="$(cat)"
    if printf "%s" "$content" | grep -q "live-neg-dest-deny"; then
      echo "error: network timeout connecting to apiserver"
      exit 1
    fi
    echo "application.argoproj.io created"; exit 0 ;;
  delete*|*"--ignore-not-found"*) exit 0 ;;
  *) exit 0 ;;
esac
'
rc="$(run_check_rc "$DESTGUARD" LIVE_MODE=mutating $POLL_OVERRIDE)"
if [ "$rc" -ne 0 ] && [ "$rc" -ne "$LIVE_RC_SKIP" ]; then
  _pass "destination: wrong denial reason => FAIL (non-zero exit $rc)"
else
  _fail "destination: wrong denial reason should produce FAIL" \
    "got exit $rc (expected non-zero non-skip)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Check 3: rbac-crossplane-scope-guard.sh
# ═══════════════════════════════════════════════════════════════════════════════
RBACGUARD="rbac-crossplane-scope-guard.sh"

echo ""
echo "── rbac-scope: (a) skips in readonly ────────────────────────────────"
assert_eq "rbac: LIVE_MODE=readonly => skip (2)" \
  "$LIVE_RC_SKIP" \
  "$(run_check_rc "$RBACGUARD" LIVE_MODE=readonly $POLL_OVERRIDE)"

echo ""
echo "── rbac-scope: (b) PASSES when guard fires (SA cannot get CSS) ───────"
# auth can-i uses $* (no stdin) so $CMD matching works directly.
write_kubectl '
CMD="$*"
case "$CMD" in
  "get ns crossplane-system")
    echo "crossplane-system   Active"; exit 0 ;;
  "get clusterrole crossplane-composite-externalsecrets")
    echo "crossplane-composite-externalsecrets   ClusterRole"; exit 0 ;;
  "get clusterrolebinding crossplane-composite-externalsecrets")
    echo "crossplane-composite-externalsecrets   ClusterRoleBinding"; exit 0 ;;
  auth*can-i*get*clustersecretstores*)
    # Guard fires: the SA cannot get ClusterSecretStores.
    echo "no"
    exit 1 ;;
  auth*can-i*get*externalsecrets*)
    # Positive control: the SA CAN get ExternalSecrets.
    echo "yes"
    exit 0 ;;
  *) exit 0 ;;
esac
'
assert_eq "rbac: guard fires (SA denied CSS) => pass (0)" \
  "$LIVE_RC_PASS" \
  "$(run_check_rc "$RBACGUARD" LIVE_MODE=mutating $POLL_OVERRIDE)"

echo ""
echo "── rbac-scope: (c) FAILS when guard does NOT fire (SA allowed CSS) ───"
write_kubectl '
CMD="$*"
case "$CMD" in
  "get ns crossplane-system")
    echo "crossplane-system   Active"; exit 0 ;;
  "get clusterrole crossplane-composite-externalsecrets")
    echo "crossplane-composite-externalsecrets   ClusterRole"; exit 0 ;;
  "get clusterrolebinding crossplane-composite-externalsecrets")
    echo "crossplane-composite-externalsecrets   ClusterRoleBinding"; exit 0 ;;
  auth*can-i*get*clustersecretstores*)
    # Guard DID NOT fire: SA is mistakenly allowed.
    echo "yes"
    exit 0 ;;
  auth*can-i*get*externalsecrets*)
    echo "yes"; exit 0 ;;
  *) exit 0 ;;
esac
'
rc="$(run_check_rc "$RBACGUARD" LIVE_MODE=mutating $POLL_OVERRIDE)"
if [ "$rc" -ne 0 ] && [ "$rc" -ne "$LIVE_RC_SKIP" ]; then
  _pass "rbac: guard did not fire (SA allowed CSS) => FAIL (non-zero exit $rc)"
else
  _fail "rbac: guard did not fire should produce FAIL" \
    "got exit $rc (expected non-zero non-skip)"
fi

echo ""
echo "── rbac-scope: (d) FAILS when denied for the WRONG reason ───────────"
# SA is denied but the output is ambiguous — neither "no" nor "Forbidden".
# The check's "unexpected output" branch exits non-zero.
write_kubectl '
CMD="$*"
case "$CMD" in
  "get ns crossplane-system")
    echo "crossplane-system   Active"; exit 0 ;;
  "get clusterrole crossplane-composite-externalsecrets")
    echo "crossplane-composite-externalsecrets   ClusterRole"; exit 0 ;;
  "get clusterrolebinding crossplane-composite-externalsecrets")
    echo "crossplane-composite-externalsecrets   ClusterRoleBinding"; exit 0 ;;
  auth*can-i*get*clustersecretstores*)
    # Ambiguous / unexpected output — not a clean "no" or "yes".
    echo "unknown-state"
    exit 1 ;;
  auth*can-i*get*externalsecrets*)
    echo "yes"; exit 0 ;;
  *) exit 0 ;;
esac
'
rc="$(run_check_rc "$RBACGUARD" LIVE_MODE=mutating $POLL_OVERRIDE)"
if [ "$rc" -ne 0 ] && [ "$rc" -ne "$LIVE_RC_SKIP" ]; then
  _pass "rbac: wrong/ambiguous denial signal => FAIL (non-zero exit $rc)"
else
  _fail "rbac: wrong denial reason should produce FAIL" \
    "got exit $rc (expected non-zero non-skip)"
fi

# ──────────────────────────────────────────────────────────────────────────────
assert_summary
