#!/usr/bin/env bash
# Unit tests for the argocd app-of-apps bootstrap.
#
# Bug class defended:
#   - bootstrap.yaml accidentally placed under argocd/apps/ — would
#     create a self-referential sync loop where the bootstrap manages
#     itself
#   - bootstrap excludes the wrong filename — silent self-loop again
#   - bootstrap uses project=k8-platform instead of default — fails to
#     apply on first Terraform run because the project doesn't exist
#     yet (the bootstrap is what creates it)
#   - bootstrap sync wave NOT lower than child Apps — race where a child
#     references a Project that hasn't been created yet
#   - terraform_data.argocd_bootstrap missing or pointing at a stale
#     path — bootstrap never applied; nothing in argocd/ ever syncs
#     from Git
#
# Pure static; no kubectl, no terraform required.

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

# shellcheck disable=SC1091
. tests/lib/assert.sh

BOOTSTRAP=argocd/bootstrap.yaml
HELM_TF=terraform/management/helm.tf

# ---- 1. Bootstrap file exists at the expected path ----------------------
if [ -f "$BOOTSTRAP" ]; then
  _pass "bootstrap_file_exists"
else
  _fail "bootstrap_file_exists" "$BOOTSTRAP missing"
  assert_summary
fi

# ---- 2. Bootstrap NOT placed under argocd/apps/ -------------------------
if [ -f argocd/apps/bootstrap.yaml ]; then
  _fail "bootstrap_not_under_apps_dir" "found argocd/apps/bootstrap.yaml — would create a self-referential loop"
else
  _pass "bootstrap_not_under_apps_dir"
fi

# ---- 3. Bootstrap is a single Application -------------------------------
KIND=$(yq -r '.kind' "$BOOTSTRAP")
NAME=$(yq -r '.metadata.name' "$BOOTSTRAP")
NS=$(yq -r '.metadata.namespace' "$BOOTSTRAP")
assert_eq "bootstrap_kind"      "Application" "$KIND"
assert_eq "bootstrap_name"      "bootstrap"   "$NAME"
assert_eq "bootstrap_namespace" "argocd"      "$NS"

# ---- 4. project: default (not k8-platform — that project doesn't exist
#         yet at bootstrap time; bootstrap is what creates it) ------------
PROJ=$(yq -r '.spec.project' "$BOOTSTRAP")
assert_eq "bootstrap_project_default" "default" "$PROJ"

# ---- 5. source.path = "argocd" + recurse: true --------------------------
SRC_PATH=$(yq -r '.spec.source.path' "$BOOTSTRAP")
RECURSE=$(yq -r '.spec.source.directory.recurse' "$BOOTSTRAP")
assert_eq "bootstrap_source_path"     "argocd" "$SRC_PATH"
assert_eq "bootstrap_directory_recurse" "true" "$RECURSE"

# ---- 6. directory.exclude lists bootstrap.yaml --------------------------
#
# Defends contract: without this exclusion, the bootstrap App tries to
# manage itself, producing a sync loop and "OutOfSync" status that no
# self-heal can clear.
EXCLUDE=$(yq -r '.spec.source.directory.exclude' "$BOOTSTRAP")
case "$EXCLUDE" in
  *bootstrap.yaml*) _pass "bootstrap_excludes_itself_from_sync" ;;
  *)                _fail "bootstrap_excludes_itself_from_sync" "exclude='$EXCLUDE' does not list bootstrap.yaml" ;;
esac

# ---- 7. sync-wave is the lowest in the repo (most-negative) ------------
#
# Defends contract: bootstrap MUST sync before any child Application or
# AppProject so the Project they all reference exists when they
# reconcile. Comparing as integers (handles negatives).
BOOTSTRAP_WAVE=$(yq -r '.metadata.annotations."argocd.argoproj.io/sync-wave"' "$BOOTSTRAP")
lowest_child_wave=0
for app in argocd/apps/*.yaml argocd/projects/*.yaml; do
  [ -f "$app" ] || continue
  [ "$(basename "$app")" = ".gitkeep" ] && continue
  w=$(yq -r '.metadata.annotations."argocd.argoproj.io/sync-wave" // "0"' "$app")
  case "$w" in
    null) w=0 ;;
  esac
  if [ "$w" -lt "$lowest_child_wave" ] 2>/dev/null; then
    lowest_child_wave=$w
  fi
done
if [ "$BOOTSTRAP_WAVE" -lt "$lowest_child_wave" ] 2>/dev/null; then
  _pass "bootstrap_sync_wave_lower_than_all_children"
else
  _fail "bootstrap_sync_wave_lower_than_all_children" "bootstrap=$BOOTSTRAP_WAVE lowest-child=$lowest_child_wave"
fi

# ---- 8. automated prune + selfHeal -------------------------------------
PRUNE=$(yq -r '.spec.syncPolicy.automated.prune' "$BOOTSTRAP")
SH=$(yq -r '.spec.syncPolicy.automated.selfHeal' "$BOOTSTRAP")
assert_eq "bootstrap_automated_prune"    "true" "$PRUNE"
assert_eq "bootstrap_automated_selfHeal" "true" "$SH"

# ---- 9. targetRevision pinned -----------------------------------------
REV=$(yq -r '.spec.source.targetRevision' "$BOOTSTRAP")
case "$REV" in
  ""|null|HEAD) _fail "bootstrap_revision_pinned" "got '$REV'" ;;
  *)            _pass "bootstrap_revision_pinned" ;;
esac

# ---- 10. terraform_data.argocd_bootstrap is wired in helm.tf -----------
if grep -qE 'resource "terraform_data" "argocd_bootstrap"' "$HELM_TF"; then
  _pass "tf_argocd_bootstrap_resource_present"
else
  _fail "tf_argocd_bootstrap_resource_present" "no terraform_data.argocd_bootstrap in $HELM_TF"
fi

# ---- 11. terraform_data references the actual bootstrap.yaml path ------
if grep -q 'argocd/bootstrap.yaml' "$HELM_TF"; then
  _pass "tf_argocd_bootstrap_references_correct_path"
else
  _fail "tf_argocd_bootstrap_references_correct_path" "helm.tf does not reference argocd/bootstrap.yaml"
fi

# ---- 12. terraform_data depends on helm_release.argocd ------------------
#
# Defends contract: without depends_on, Terraform may try to kubectl
# apply before argocd-server is up, producing flaky first-run failures.
# Capture-then-grep (here-string) rather than `awk ... | grep -q`: the latter
# can intermittently false-FAIL under `set -o pipefail` when grep -q exits on
# first match and SIGPIPEs the still-writing awk (OI-2026-06-05-1).
_argocd_bootstrap_block="$(awk '/resource "terraform_data" "argocd_bootstrap"/,/^}/' "$HELM_TF")"
if grep -q 'depends_on.*helm_release.argocd' <<<"$_argocd_bootstrap_block"; then
  _pass "tf_argocd_bootstrap_depends_on_helm_release"
else
  _fail "tf_argocd_bootstrap_depends_on_helm_release" "missing depends_on = [helm_release.argocd]"
fi

# ---- 13. terraform_data waits for argocd-server Available --------------
#
# Defends contract: kubectl wait must precede kubectl apply, otherwise
# the API call lands before ArgoCD's CRDs are registered.
if grep -qE 'kubectl wait.*argocd' <<<"$_argocd_bootstrap_block"; then
  _pass "tf_argocd_bootstrap_waits_for_server"
else
  _fail "tf_argocd_bootstrap_waits_for_server" "missing kubectl wait for argocd-server before apply"
fi

assert_summary
