#!/bin/bash
# SessionStart hook — install the CI-pinned CLI toolchain at the start of
# every (remote/web) session so the agent is tool-ready immediately.
#
# The Claude-Code-on-the-web sandbox is ephemeral: each session starts with
# none of aws/argocd/helm/yq/crossplane installed, and the EKS kube-API is
# private-CA-blocked, so live ops depend on the argocd CLI + aws CLI being
# present from turn one. This hook delegates to scripts/sandbox-setup.sh
# (versions pinned in tests/chainsaw/versions.env) so the sandbox toolchain
# always matches CI. Idempotent: a tool already at the pinned version is a
# no-op, so re-runs (resume/clear/compact) are cheap.
set -uo pipefail

# Only touch the ephemeral remote sandbox; local dev machines manage their
# own toolchain (avoid writing to a developer's /usr/local/bin).
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

REPO_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

if ! bash "${REPO_DIR}/scripts/sandbox-setup.sh"; then
  echo "session-start: sandbox-setup.sh reported a failure; some CLIs may be missing." >&2
  echo "session-start: re-run manually with: bash scripts/sandbox-setup.sh" >&2
fi

# Never block session start on a transient install/network hiccup — the
# agent runs scripts/whereami.sh first (AGENTS §8.1) and will see anything missing.
exit 0
