#!/usr/bin/env bash
# Unit tests for argocd/apps/*.yaml.
#
# Bug class defended (adversarial-reviewer A.8/A.9):
#   - Application targetRevision unpinned (`HEAD` or empty) silently
#     follows whatever the branch tip is, including force-pushes.
#   - Application source.path points at a non-existent directory.
#   - syncPolicy.automated.prune/selfHeal not set — drift accumulates
#     because Argo neither prunes deleted resources nor heals manual
#     edits.

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

# shellcheck disable=SC1091
. tests/lib/assert.sh

APP_DIR=argocd/apps

found_any=0
for app in "$APP_DIR"/*.yaml; do
  [ "$(basename "$app")" = ".gitkeep" ] && continue
  found_any=1
  base=$(basename "$app")

  KIND=$(yq -r '.kind' "$app" 2>/dev/null)
  [ "$KIND" = "Application" ] || continue

  # ---- targetRevision pinned ------------------------------------------
  #
  # `main` is acceptable for this learning-platform; HEAD or empty is
  # not. A pinned commit SHA is also acceptable. (For a stricter prod
  # posture, change the allowlist to require a SHA or tag.)
  REV=$(yq -r '.spec.source.targetRevision' "$app")
  case "$REV" in
    ""|null|HEAD)
      _fail "argocd_app_revision_pinned:$base" "targetRevision='$REV' — must be main, a tag, or a SHA"
      ;;
    *)
      _pass "argocd_app_revision_pinned:$base"
      ;;
  esac

  # ---- source.path resolves to a real dir ------------------------------
  PATH_=$(yq -r '.spec.source.path' "$app")
  if [ -n "$PATH_" ] && [ "$PATH_" != "null" ] && [ -d "$PATH_" ]; then
    _pass "argocd_app_source_path_exists:$base"
  else
    _fail "argocd_app_source_path_exists:$base" "spec.source.path='$PATH_' is not a real directory"
  fi

  # ---- syncPolicy.automated.{prune,selfHeal} — required unless the app
  # is explicitly opted out of automated sync.
  #
  # Some Applications provision destructive/expensive resources (e.g.
  # PlatformCluster claims → real EKS clusters at ~15 min provisioning
  # and real $$). For those, syncPolicy.automated is intentionally
  # ABSENT — sync is an operator-confirmed action. Detect that case by
  # looking for the `.spec.syncPolicy.automated` block being null AND
  # the file header documenting the manual-sync choice. Otherwise
  # require both prune and selfHeal = true.
  AUTOMATED=$(yq -r '.spec.syncPolicy.automated' "$app")
  if [ "$AUTOMATED" = "null" ]; then
    if grep -q "manual sync only\|without automated sync\|no syncPolicy.automated" "$app"; then
      _pass "argocd_app_manual_sync_documented:$base"
    else
      _fail "argocd_app_manual_sync_documented:$base" \
        "spec.syncPolicy.automated is absent but the file does not document the manual-sync choice"
    fi
  else
    PRUNE=$(yq -r '.spec.syncPolicy.automated.prune' "$app")
    assert_eq "argocd_app_automated_prune:$base" "true" "$PRUNE"
    SH=$(yq -r '.spec.syncPolicy.automated.selfHeal' "$app")
    assert_eq "argocd_app_automated_selfHeal:$base" "true" "$SH"
  fi

  # ---- project is the platform AppProject ------------------------------
  PROJ=$(yq -r '.spec.project' "$app")
  if [ "$PROJ" = "k8-platform" ]; then
    _pass "argocd_app_project_k8_platform:$base"
  else
    _fail "argocd_app_project_k8_platform:$base" "spec.project='$PROJ' (expected 'k8-platform')"
  fi
done

if [ "$found_any" -eq 0 ]; then
  _pass "argocd_app_dir_empty_no_apps_to_check"
fi

assert_summary
