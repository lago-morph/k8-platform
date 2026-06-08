#!/usr/bin/env bash
# FAIL-closed live-evidence gate (FINAL-PLAN §4.3 — the round-3 centerpiece).
#
# The push/PR static gate that makes "on by default" and "coupled to the change"
# MECHANICAL. Because the only live surface is a *manual* workflow_dispatch of
# terraform-test.yml, a UI dropdown default cannot guarantee "every bring-up".
# This gate FAILs (never WARNs) unless an unforgeable, fresh live-evidence record
# exists for the deployed (config-SHA x account-id x cluster-name x profile).
#
# It lives OUTSIDE the live suite, so it catches the non-invocation cases the
# inside-suite all-skip⇒RED cannot: a verify-only/bare-apply/plan dispatch, a
# config-only ArgoCD sync with no dispatch at all, or a crash before the final
# phase.
#
# UNFORGEABLE: the evidence is a GitHub Actions run-ID cross-check (the repo's
# chainsaw-verify.yml pattern). A satisfying record must reference a real
# apply-and-verify run that the API confirms exists, has conclusion=success, ran
# against THIS account-id and cluster-name, recorded WHICH profile produced it,
# and is newer than the account's bootstrap. The run's evidence is machine-emitted
# on the §4.4 clean-pass exit code only — never a hand-writable free-text marker.
#
# Usage (CI, push-time):
#   live-evidence-gate.sh \
#     --config-sha   <sha>          # the deployed config SHA (HEAD, or the
#                                   #   crossplane/**+policies/** subtree SHA for
#                                   #   a config-only change)
#     --account      <account-id>
#     --cluster      <cluster-name>
#     --required-profile full|verify-only
#     [--bootstrap-after <RFC3339>] # evidence must be newer than this
#
# Evidence source (the seam):
#   LIVE_EVIDENCE_FIXTURE=<file>  — a JSON array of evidence records (for unit
#                                   tests). When unset, fetch_evidence calls the
#                                   Actions API (see fetch_evidence()).
# Each record: {run_id, sha, account, cluster, profile, conclusion, created_at}.
#
# Exit: 0 = fresh satisfying evidence found (GREEN); 1 = none (RED, "run the
# build"); 2 = usage error.

set -euo pipefail

CONFIG_SHA="" ACCOUNT="" CLUSTER="" REQUIRED_PROFILE="" BOOTSTRAP_AFTER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --config-sha)        CONFIG_SHA="$2"; shift 2 ;;
    --account)           ACCOUNT="$2"; shift 2 ;;
    --cluster)           CLUSTER="$2"; shift 2 ;;
    --required-profile)  REQUIRED_PROFILE="$2"; shift 2 ;;
    --bootstrap-after)   BOOTSTRAP_AFTER="$2"; shift 2 ;;
    *) echo "live-evidence-gate: unknown arg '$1'" >&2; exit 2 ;;
  esac
done
for v in CONFIG_SHA ACCOUNT CLUSTER REQUIRED_PROFILE; do
  [ -n "${!v}" ] || { echo "live-evidence-gate: --${v,,} required" >&2; exit 2; }
done
case "$REQUIRED_PROFILE" in full|verify-only) ;; *)
  echo "live-evidence-gate: --required-profile must be full|verify-only" >&2; exit 2 ;;
esac

# fetch_evidence — emit the JSON array of evidence records on stdout. The unit
# tests inject LIVE_EVIDENCE_FIXTURE; CI overrides this to query the Actions API
# for apply-and-verify runs on CONFIG_SHA and join their machine-emitted
# (account,cluster,profile) artifact. Kept as a single seam so the LOGIC below
# is identical in test and CI.
fetch_evidence() {
  if [ -n "${LIVE_EVIDENCE_FIXTURE:-}" ]; then
    cat "$LIVE_EVIDENCE_FIXTURE"
    return
  fi
  # CI path: query the Actions API for successful runs of the live-verify
  # producer workflow on this SHA, download each run's machine-emitted
  # `live-evidence` artifact (account,cluster,profile,conclusion,created_at —
  # uploaded ONLY on the §4.4 clean-pass exit code), and join the records. The
  # artifact join is the unforgeable half: a hand-written run_id has no matching
  # successful run + artifact. Any missing token / failed call / absent artifact
  # yields the empty set, which is correctly RED (fail-closed, never
  # green-by-absence).
  : "${GH_TOKEN:=${GITHUB_TOKEN:-}}"
  if [ -z "${GH_TOKEN:-}" ] || [ -z "${GITHUB_REPOSITORY:-}" ]; then
    echo '[]'; return
  fi
  _gh_api() {
    curl -fsSL \
      -H "Authorization: Bearer $GH_TOKEN" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" "$@"
  }
  local base="https://api.github.com/repos/${GITHUB_REPOSITORY}"
  local runs_json run_ids tmp out rid arts aid zip ef
  runs_json="$(_gh_api "${base}/actions/workflows/live-verify.yml/runs?head_sha=${CONFIG_SHA}&per_page=50" 2>/dev/null)" \
    || { echo '[]'; return; }
  run_ids="$(printf '%s' "$runs_json" | jq -r '.workflow_runs[]? | select(.conclusion=="success") | .id' 2>/dev/null)"
  tmp="$(mktemp -d)"; out="${tmp}/records.ndjson"; : > "$out"
  for rid in $run_ids; do
    arts="$(_gh_api "${base}/actions/runs/${rid}/artifacts" 2>/dev/null)" || continue
    aid="$(printf '%s' "$arts" | jq -r '.artifacts[]? | select(.name=="live-evidence") | .id' 2>/dev/null | head -1)"
    { [ -n "$aid" ] && [ "$aid" != "null" ]; } || continue
    zip="${tmp}/${aid}.zip"
    curl -fsSL -H "Authorization: Bearer $GH_TOKEN" \
      "${base}/actions/artifacts/${aid}/zip" -o "$zip" 2>/dev/null || continue
    unzip -o -q "$zip" -d "${tmp}/${aid}" 2>/dev/null || continue
    ef="$(find "${tmp}/${aid}" -type f -name '*.json' 2>/dev/null | head -1)"
    [ -n "$ef" ] || continue
    jq -c '.' "$ef" >> "$out" 2>/dev/null || true
  done
  jq -s '.' "$out" 2>/dev/null || echo '[]'
  rm -rf "$tmp"
}

# The LOGIC — identical in test and CI. Evidence is passed via env (not stdin),
# so the python heredoc does not collide with the evidence pipe.
EVIDENCE_JSON="$(fetch_evidence)"
result="$(CONFIG_SHA="$CONFIG_SHA" ACCOUNT="$ACCOUNT" \
  CLUSTER="$CLUSTER" REQUIRED_PROFILE="$REQUIRED_PROFILE" \
  BOOTSTRAP_AFTER="$BOOTSTRAP_AFTER" EVIDENCE_JSON="$EVIDENCE_JSON" python3 - <<'PY'
import json, os

sha   = os.environ["CONFIG_SHA"]
acct  = os.environ["ACCOUNT"]
clus  = os.environ["CLUSTER"]
req   = os.environ["REQUIRED_PROFILE"]
boot  = os.environ.get("BOOTSTRAP_AFTER", "")

try:
    records = json.loads(os.environ.get("EVIDENCE_JSON") or "[]")
except Exception:
    records = []

# A verify-only requirement is satisfied by full OR verify-only evidence; a full
# requirement is satisfied ONLY by full evidence (a change re-arms `full`, and a
# verify-only result can never masquerade as full — §4.3).
def profile_ok(ev_profile):
    if req == "full":
        return ev_profile == "full"
    return ev_profile in ("full", "verify-only")

best = None
for r in records:
    if r.get("conclusion") != "success":      continue
    if r.get("sha") != sha:                    continue
    if str(r.get("account")) != str(acct):     continue
    if r.get("cluster") != clus:               continue
    if not profile_ok(r.get("profile", "")):   continue
    if boot and r.get("created_at", "") <= boot:  # must be newer than bootstrap
        continue
    if best is None or r.get("created_at", "") > best.get("created_at", ""):
        best = r

if best is not None:
    print("GREEN " + json.dumps({k: best.get(k) for k in
          ("run_id", "sha", "account", "cluster", "profile", "created_at")}))
else:
    print("RED")
PY
)"

if [ "${result%% *}" = "GREEN" ]; then
  echo "✅ live-evidence gate: fresh ${REQUIRED_PROFILE} evidence found for"
  echo "   (sha=${CONFIG_SHA:0:12} account=${ACCOUNT} cluster=${CLUSTER})"
  echo "   ${result#GREEN }"
  exit 0
fi

cat >&2 <<EOF
❌ live-evidence gate: NO fresh green apply-and-verify run for
     config-SHA = ${CONFIG_SHA}
     account    = ${ACCOUNT}
     cluster    = ${CLUSTER}
     profile    = ${REQUIRED_PROFILE} (required)

This is FAIL-closed by design (FINAL-PLAN §4.3): "on by default" is mechanical.
A change to crossplane/** or policies/** re-arms 'full' and reconciles to the
live hub with no apply-and-verify dispatch — so it must be verified before merge.

To resolve: dispatch terraform-test.yml action=apply-and-verify (phase=management)
against this SHA, let the live suite pass clean (LIVE_PROFILE=${REQUIRED_PROFILE}),
then re-run this gate. The first apply for a fresh/rotated account has no prior
marker by construction: that is expect-full-from-git (RED, "run the build"),
never green-by-absence.
EOF
exit 1
