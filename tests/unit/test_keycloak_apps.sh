#!/usr/bin/env bash
# Unit tests for the phase-5 Keycloak (auth) scaffolding (REQ-AUTH-01..10).
#
# Two contracts:
#   (A) argocd/apps/spoke/keycloak.yaml satisfies the same spoke-Application
#       contract as the phase-3 spoke apps (project=platform-spoke,
#       destination.name, pinned targetRevision, automated prune+selfHeal,
#       sync-wave) — and the Keycloak-specific pins (Bitnami chart, wave 40,
#       Bitnami repo allowlisted in the AppProject).
#   (B) the kc ClusterRoleBindings under clusters/platform/rbac/ are named with
#       a prefix the spoke Kyverno cluster-admin guard allowlists
#       (policies/audit/10-spoke-no-cluster-admin-binding.yaml: k8-platform-* /
#       kc-k8s-admins-*) so the REQ-AUTH-09 admin binding is not flagged as a
#       rogue cluster-admin grant — AND the admin binding actually targets
#       cluster-admin while the viewer binding targets `view`.
#
# Assertion shape reviewed via an adversarial pass (AGENTS §6.4): the
# load-bearing risk is a binding that grants cluster-admin under a name the
# Kyverno exclude list does NOT cover (it would be audited as an escalation),
# OR a Keycloak Application that drifts from the spoke contract.
#
# Uses raw `yq -r` (python/jq-flavored yq, matching test_spoke_apps.sh) — NOT
# the eval-all helpers, which assume mikefarah yq.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-helpers.sh"
require_tool yq

ROOT="$HERE/../.."
APP="$ROOT/argocd/apps/spoke/keycloak.yaml"
PROJ="$ROOT/argocd/projects/platform-spoke.yaml"
POLICY="$ROOT/policies/audit/10-spoke-no-cluster-admin-binding.yaml"
RBAC_DIR="$ROOT/clusters/platform/rbac"
FAIL=0

# ── (A) the Keycloak spoke ApplicationSet contract (ADR-0010) ───────────────
# Keycloak is PLATFORM-ONLY: the generator pins short-name=spoke in addition
# to cluster-role=spoke (the auth layer does not fan out to workload spokes).
# The generic ApplicationSet shape (goTemplate, missingkey=error,
# preserveResourcesOnDeletion, destination={{.name}}) is gated by
# test_spoke_apps.sh; here we gate the Keycloak-specific pins.
[ -f "$APP" ] || { echo "FAIL: $APP missing"; exit 1; }

kind="$(yq -r '.kind' "$APP")"
[ "$kind" = "ApplicationSet" ] && echo "ok: kind=ApplicationSet" \
  || { echo "FAIL: kind=$kind, want ApplicationSet (ADR-0010)"; FAIL=1; }

pin="$(yq -r '.spec.generators[0].clusters.selector.matchLabels."k8-platform.io/short-name"' "$APP")"
[ "$pin" = "spoke" ] && echo "ok: generator pinned to the platform spoke (short-name=spoke)" \
  || { echo "FAIL: keycloak must be platform-only — generator short-name=$pin, want spoke"; FAIL=1; }

proj="$(yq -r '.spec.template.spec.project' "$APP")"
[ "$proj" = "platform-spoke" ] && echo "ok: template project=platform-spoke" \
  || { echo "FAIL: template project=$proj, want platform-spoke"; FAIL=1; }

dname="$(yq -r '.spec.template.spec.destination.name' "$APP")"
dserver="$(yq -r '.spec.template.spec.destination.server' "$APP")"
[ "$dname" = '{{.name}}' ] && echo "ok: template destination.name={{.name}}" \
  || { echo "FAIL: template destination.name=$dname, want {{.name}}"; FAIL=1; }
[ "$dserver" = "null" ] && echo "ok: no destination.server (spoke by generated name)" \
  || { echo "FAIL: destination.server set ($dserver) — spokes are by name"; FAIL=1; }

dns="$(yq -r '.spec.template.spec.destination.namespace' "$APP")"
[ "$dns" = "keycloak" ] && echo "ok: destination.namespace=keycloak" \
  || { echo "FAIL: destination.namespace=$dns, want keycloak"; FAIL=1; }

# Bitnami chart source, pinned (not HEAD/empty).
chart="$(yq -r '.spec.template.spec.sources[]? | select(.chart != null) | .chart' "$APP")"
[ "$chart" = "keycloak" ] && echo "ok: chart=keycloak" \
  || { echo "FAIL: chart=$chart, want keycloak"; FAIL=1; }

chartrepo="$(yq -r '.spec.template.spec.sources[]? | select(.chart != null) | .repoURL' "$APP")"
[ "$chartrepo" = "https://charts.bitnami.com/bitnami" ] \
  && echo "ok: chart repoURL=bitnami" \
  || { echo "FAIL: chart repoURL=$chartrepo, want https://charts.bitnami.com/bitnami"; FAIL=1; }

rev="$(yq -r '.spec.template.spec.sources[]? | select(.chart != null) | .targetRevision' "$APP")"
case "$rev" in
  HEAD|null|"") echo "FAIL: chart targetRevision '$rev' not pinned"; FAIL=1;;
  *) echo "ok: chart targetRevision pinned ($rev)";;
esac

# The pinned chart repo MUST be allowlisted EXACT in the AppProject sourceRepos
# (auto-008 S1 — no wildcard). Otherwise ArgoCD refuses the source at sync.
if yq -e '.spec.sourceRepos[] | select(. == "https://charts.bitnami.com/bitnami")' "$PROJ" >/dev/null 2>&1; then
  echo "ok: bitnami repo allowlisted in platform-spoke AppProject"
else
  echo "FAIL: https://charts.bitnami.com/bitnami not in platform-spoke sourceRepos"; FAIL=1
fi

# multi-source: this repo provides $values (values file in git).
valref="$(yq -r '.spec.template.spec.sources[]? | select(.ref == "values") | .repoURL' "$APP")"
[ "$valref" = "https://github.com/lago-morph/k8-platform.git" ] \
  && echo "ok: \$values source is this repo" \
  || { echo "FAIL: \$values ref source=$valref, want this repo"; FAIL=1; }

# The auth hostname is templated from the cluster facts (never a committed
# domain): auth.<subdomain>.<domain>.
khost="$(yq -r '.spec.template.spec.sources[]? | select(.chart != null) | .helm.valuesObject.ingress.hostname' "$APP")"
case "$khost" in
  auth.*k8-platform.io/subdomain*k8-platform.io/domain*) echo "ok: ingress.hostname templated from cluster facts";;
  *) echo "FAIL: ingress.hostname must be templated auth.<subdomain>.<domain> from cluster facts (got $khost)"; FAIL=1;;
esac

# The OIDC issuer must be https://auth.<subdomain>.<domain> (clean build #3:
# the NLB terminates TLS at L4, nginx forwards X-Forwarded-Proto=http, and
# without an explicit KC_HOSTNAME keycloak advertised an http:// issuer —
# which would poison every OIDC consumer). KC_HOSTNAME is templated from
# the SAME cluster facts as ingress.hostname; strict-https forces the
# https scheme on frontend URLs.
kchost="$(yq -r '.spec.template.spec.sources[]? | select(.chart != null) | .helm.valuesObject.extraEnvVars[]? | select(.name == "KC_HOSTNAME") | .value' "$APP")"
case "$kchost" in
  auth.*k8-platform.io/subdomain*k8-platform.io/domain*) echo "ok: KC_HOSTNAME templated from cluster facts";;
  *) echo "FAIL: KC_HOSTNAME extraEnvVar must be templated auth.<subdomain>.<domain> from cluster facts (got '$kchost')"; FAIL=1;;
esac
[ "$kchost" = "$khost" ] \
  && echo "ok: KC_HOSTNAME identical to ingress.hostname" \
  || { echo "FAIL: KC_HOSTNAME ('$kchost') must equal ingress.hostname ('$khost')"; FAIL=1; }

strict="$(yq -r '.spec.template.spec.sources[]? | select(.chart != null) | .helm.valuesObject.extraEnvVars[]? | select(.name == "KC_HOSTNAME_STRICT_HTTPS") | .value' "$APP")"
[ "$strict" = "true" ] \
  && echo "ok: KC_HOSTNAME_STRICT_HTTPS=true (https issuer behind the L4-TLS NLB)" \
  || { echo "FAIL: KC_HOSTNAME_STRICT_HTTPS must be \"true\" (got '$strict')"; FAIL=1; }

prune="$(yq -r '.spec.template.spec.syncPolicy.automated.prune' "$APP")"
sh="$(yq -r '.spec.template.spec.syncPolicy.automated.selfHeal' "$APP")"
{ [ "$prune" = "true" ] && [ "$sh" = "true" ]; } && echo "ok: automated prune+selfHeal" \
  || { echo "FAIL: need automated prune+selfHeal (prune=$prune selfHeal=$sh)"; FAIL=1; }

wave="$(yq -r '.spec.template.metadata.annotations."argocd.argoproj.io/sync-wave"' "$APP")"
[ "$wave" = "40" ] && echo "ok: template sync-wave=40 (after base add-ons)" \
  || { echo "FAIL: template sync-wave=$wave, want 40 (REQ-AUTH ordering)"; FAIL=1; }

# ── (B) the kc RBAC bindings + Kyverno allowlist prefix ────────────────────
[ -d "$RBAC_DIR" ] || { echo "FAIL: $RBAC_DIR missing"; exit 1; }
[ -f "$POLICY" ] || { echo "FAIL: $POLICY missing"; exit 1; }

# The cluster-admin guard's exclude names (the allowlist prefixes). A kc admin
# binding MUST be covered by one of these globs or it will be audited as a
# rogue cluster-admin grant.
mapfile -t ALLOW < <(yq -r '.spec.rules[].exclude.any[].resources.names[]?' "$POLICY")
echo "ok: Kyverno allowlist prefixes: ${ALLOW[*]}"

# helper: does NAME match any allowlist glob?
name_allowlisted() {
  local n="$1" g
  for g in "${ALLOW[@]}"; do
    # shellcheck disable=SC2053
    case "$n" in $g) return 0;; esac
  done
  return 1
}

found_admin=0
found_viewer=0
for f in "$RBAC_DIR"/kc-*.yaml; do
  [ -e "$f" ] || continue
  base="$(basename "$f")"
  k="$(yq -r '.kind' "$f")"
  [ "$k" = "ClusterRoleBinding" ] || { echo "FAIL[$base]: kind=$k, want ClusterRoleBinding"; FAIL=1; continue; }

  name="$(yq -r '.metadata.name' "$f")"
  roleref="$(yq -r '.roleRef.name' "$f")"
  subj="$(yq -r '.subjects[0].name' "$f")"
  subjkind="$(yq -r '.subjects[0].kind' "$f")"

  # subjects must be the prefixed Keycloak GROUPS (kc:k8s-*), never users.
  [ "$subjkind" = "Group" ] && echo "ok[$base]: subject kind=Group" \
    || { echo "FAIL[$base]: subject kind=$subjkind, want Group"; FAIL=1; }
  case "$subj" in
    kc:k8s-*) echo "ok[$base]: subject=$subj (kc: prefixed group)";;
    *) echo "FAIL[$base]: subject=$subj, want kc:k8s-* (REQ-AUTH-07/09)"; FAIL=1;;
  esac

  if [ "$roleref" = "cluster-admin" ]; then
    found_admin=1
    # THE load-bearing assertion: a cluster-admin binding MUST be allowlisted by
    # name in the Kyverno guard, else it is flagged as an escalation.
    case "$name" in
      kc-k8s-admins-*) echo "ok[$base]: admin binding name has kc-k8s-admins- prefix";;
      *) echo "FAIL[$base]: cluster-admin binding '$name' lacks kc-k8s-admins- prefix"; FAIL=1;;
    esac
    if name_allowlisted "$name"; then
      echo "ok[$base]: name '$name' is allowlisted by the Kyverno cluster-admin guard"
    else
      echo "FAIL[$base]: cluster-admin binding '$name' NOT covered by Kyverno allowlist (${ALLOW[*]})"; FAIL=1
    fi
    [ "$subj" = "kc:k8s-admins" ] && echo "ok[$base]: admin subject=kc:k8s-admins" \
      || { echo "FAIL[$base]: admin subject=$subj, want kc:k8s-admins"; FAIL=1; }
  elif [ "$roleref" = "view" ]; then
    found_viewer=1
    case "$name" in
      kc-k8s-viewers-*) echo "ok[$base]: viewer binding name has kc-k8s-viewers- prefix";;
      *) echo "FAIL[$base]: view binding '$name' lacks kc-k8s-viewers- prefix"; FAIL=1;;
    esac
    [ "$subj" = "kc:k8s-viewers" ] && echo "ok[$base]: viewer subject=kc:k8s-viewers" \
      || { echo "FAIL[$base]: viewer subject=$subj, want kc:k8s-viewers"; FAIL=1; }
  fi
done

[ "$found_admin" -eq 1 ] && echo "ok: kc:k8s-admins → cluster-admin binding present (REQ-AUTH-09)" \
  || { echo "FAIL: no kc:k8s-admins → cluster-admin binding found"; FAIL=1; }
[ "$found_viewer" -eq 1 ] && echo "ok: kc:k8s-viewers → view binding present (REQ-AUTH-09)" \
  || { echo "FAIL: no kc:k8s-viewers → view binding found"; FAIL=1; }

[ "$FAIL" -eq 0 ] && echo "PASS: Keycloak Application + kc RBAC contracts" || echo "FAILED"
exit "$FAIL"
