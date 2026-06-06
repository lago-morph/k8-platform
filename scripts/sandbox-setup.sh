#!/usr/bin/env bash
# sandbox-setup.sh — install the CI-pinned local toolchain.
#
# THE PROBLEM THIS SOLVES (durable record — OI-2026-06-06-1):
# Local unit-test runs MUST use the SAME tool versions as CI, or they
# produce false signals. The sharpest trap: many sandboxes ship the
# Python `yq` (kislyuk), but every yq-touching test (notably
# scripts/composition-render.sh's normalize_stream) needs mikefarah/yq
# (Go). The Python one silently mis-parses `yq ea '...'` and yields
# spurious golden mismatches that look like real failures.
#
# Run this ONCE at the start of a sandbox session, before running
# tests/unit/run.sh or scripts/composition-render.sh:
#
#   bash scripts/sandbox-setup.sh
#
# Every version is read from tests/chainsaw/versions.env — the single
# source of truth shared with .github/workflows/unit-tests.yml. If CI
# and the sandbox ever disagree, fix versions.env, not this script.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "${REPO_ROOT}/tests/chainsaw/versions.env"

BIN=/usr/local/bin
SUDO=""
[ -w "$BIN" ] || SUDO="sudo"

echo "== sandbox-setup: installing CI-pinned tools from versions.env =="

# --- mikefarah/yq (Go) — MUST match CI exactly -------------------------
need_yq=1
if command -v yq >/dev/null 2>&1 && yq --version 2>&1 | grep -q "mikefarah"; then
  have="$(yq --version 2>&1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' || true)"
  if [ "$have" = "$YQ_VERSION" ]; then
    echo "  yq: ${YQ_VERSION} (mikefarah) already present"
    need_yq=0
  else
    echo "  yq: replacing ${have:-unknown} with pinned ${YQ_VERSION}"
  fi
else
  echo "  yq: installing mikefarah ${YQ_VERSION} (Python yq is unsupported)"
fi
if [ "$need_yq" -eq 1 ]; then
  $SUDO curl -fsSL \
    "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" \
    -o "${BIN}/yq"
  $SUDO chmod +x "${BIN}/yq"
  yq --version
fi

# --- crossplane CLI — pinned to the chart/server version ---------------
want_xp="v${CROSSPLANE_CHART_VERSION}"
if command -v crossplane >/dev/null 2>&1 && \
   crossplane version --client 2>&1 | grep -q "${want_xp}"; then
  echo "  crossplane: ${want_xp} already present"
else
  echo "  crossplane: installing CLI ${want_xp} (releases 'crank' binary)"
  curl -fsSL \
    "https://releases.crossplane.io/stable/${want_xp}/bin/linux_amd64/crank" \
    -o /tmp/crossplane
  chmod +x /tmp/crossplane
  $SUDO mv /tmp/crossplane "${BIN}/crossplane"
  crossplane version --client || true
fi

# --- AWS CLI v2 — required for every live op + scripts/whereami.sh -------
# Not pinned (runtime tool; the v2 installer always fetches current). Skip
# if already present.
if command -v aws >/dev/null 2>&1; then
  echo "  aws: $(aws --version 2>&1) already present"
else
  echo "  aws: installing AWS CLI v2"
  tmp="$(mktemp -d)"
  curl -fsSL "https://awscliv2.zip" -o "${tmp}/awscliv2.zip" 2>/dev/null \
    || curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "${tmp}/awscliv2.zip"
  ( cd "$tmp" && unzip -q awscliv2.zip )
  $SUDO "${tmp}/aws/install" --update >/dev/null 2>&1 \
    || $SUDO "${tmp}/aws/install" >/dev/null 2>&1
  rm -rf "$tmp"
  aws --version 2>&1 || true
fi

# --- Helm — pinned to CI (azure/setup-helm version in versions.env) ------
if command -v helm >/dev/null 2>&1 && helm version --short 2>/dev/null | grep -q "${HELM_VERSION}"; then
  echo "  helm: ${HELM_VERSION} already present"
else
  echo "  helm: installing ${HELM_VERSION}"
  tmp="$(mktemp -d)"
  curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" -o "${tmp}/helm.tgz"
  tar -xzf "${tmp}/helm.tgz" -C "$tmp"
  $SUDO install -m 0755 "${tmp}/linux-amd64/helm" "${BIN}/helm"
  rm -rf "$tmp"
  helm version --short 2>&1 || true
fi

# --- ArgoCD CLI — pinned to the deployed server version -----------------
if command -v argocd >/dev/null 2>&1 && argocd version --client --short 2>/dev/null | grep -q "${ARGOCD_VERSION}"; then
  echo "  argocd: ${ARGOCD_VERSION} already present"
else
  echo "  argocd: installing ${ARGOCD_VERSION}"
  $SUDO curl -fsSL \
    "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-amd64" \
    -o "${BIN}/argocd"
  $SUDO chmod +x "${BIN}/argocd"
  argocd version --client --short 2>&1 || true
fi

echo "== sandbox-setup: done =="
echo "Note: scripts/composition-render.sh also needs a running Docker daemon"
echo "      (functions render in Docker). Start it with: sudo dockerd &"
