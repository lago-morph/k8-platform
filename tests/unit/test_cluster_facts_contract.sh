#!/usr/bin/env bash
# Gates the cluster-facts contract (ADR-0010): the spoke ApplicationSets may
# reference ONLY the contract's annotation/label keys on the cluster Secret,
# and every contract key must be documented in the ADR. This is the
# consumer-side half of the bidirectional lint; the producer-side half (the
# registration Secret must emit exactly these keys) lands with ADR-0010 PR-2
# (OI-2026-06-07-1).
#
# Also gates the structural retirement of the overlay pattern: no
# OVERLAID-AT-REGISTRATION marker may remain under argocd/apps/spoke/ — that
# marker meant "a live hand patches this app's values", the exact mechanism
# bootstrap selfHeal fought (OI-2026-06-07-2).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
SPOKE_DIR="$ROOT/argocd/apps/spoke"
ADR="$ROOT/docs/decisions/0010-cluster-facts-via-cluster-secret-annotations-and-applicationsets.md"
FAIL=0

# ── the contract (single source for this lint; mirrors the ADR table) ───────
ANNOTATION_KEYS="domain subdomain certificate-arn external-dns-role-arn region"
LABEL_KEYS="cluster-role short-name"

[ -d "$SPOKE_DIR" ] || { echo "FAIL: $SPOKE_DIR missing"; exit 1; }
[ -f "$ADR" ] || { echo "FAIL: $ADR missing (the contract must stay documented)"; exit 1; }

# ── 1. ADR documents every key this lint enforces ───────────────────────────
for k in $ANNOTATION_KEYS $LABEL_KEYS; do
  if grep -q "k8-platform.io/$k" "$ADR" || grep -q "\`$k\`" "$ADR"; then
    echo "ok[adr]: contract key '$k' documented"
  else
    echo "FAIL[adr]: contract key '$k' not found in ADR-0010 — doc and lint drifted"; FAIL=1
  fi
done

# ── 2. templates reference ONLY contract keys ───────────────────────────────
# Every `.metadata.annotations "k8-platform.io/<key>"` / `.metadata.labels
# "k8-platform.io/<key>"` template expression must use a contract key. A
# non-contract key here would generate an empty/missing value (missingkey=error
# turns it into a loud generation failure on the hub — catch it at PR time
# instead).
in_list() { local n="$1"; shift; for x in "$@"; do [ "$n" = "$x" ] && return 0; done; return 1; }

for f in "$SPOKE_DIR"/*.yaml; do
  [ -e "$f" ] || continue
  base="$(basename "$f")"

  while IFS= read -r key; do
    [ -z "$key" ] && continue
    # shellcheck disable=SC2086
    if in_list "$key" $ANNOTATION_KEYS; then
      echo "ok[$base]: annotation fact '$key' is in contract"
    else
      echo "FAIL[$base]: template references annotation k8-platform.io/$key — NOT in the ADR-0010 contract"; FAIL=1
    fi
  done < <(grep -o '\.metadata\.annotations "k8-platform\.io/[a-z-]*"' "$f" | sed 's/.*k8-platform\.io\///; s/"//' | sort -u)

  while IFS= read -r key; do
    [ -z "$key" ] && continue
    # shellcheck disable=SC2086
    if in_list "$key" $LABEL_KEYS; then
      echo "ok[$base]: label fact '$key' is in contract"
    else
      echo "FAIL[$base]: template references label k8-platform.io/$key — NOT in the ADR-0010 contract"; FAIL=1
    fi
  done < <(grep -o '\.metadata\.labels "k8-platform\.io/[a-z-]*"' "$f" | sed 's/.*k8-platform\.io\///; s/"//' | sort -u)

  # generator selectors may only select contract LABEL keys.
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    # shellcheck disable=SC2086
    if in_list "$key" $LABEL_KEYS; then
      echo "ok[$base]: generator selects contract label '$key'"
    else
      echo "FAIL[$base]: generator selects k8-platform.io/$key — NOT a contract label"; FAIL=1
    fi
  done < <(grep -o '"\?k8-platform\.io/[a-z-]*"\?:' "$f" | sed 's/"//g; s/k8-platform\.io\///; s/://' | sort -u)
done

# ── 3. the overlay pattern is structurally retired ──────────────────────────
if grep -rn "OVERLAID-AT-REGISTRATION" "$SPOKE_DIR"; then
  echo "FAIL: OVERLAID-AT-REGISTRATION marker under argocd/apps/spoke/ — the hand-overlay pattern is retired (ADR-0010)"; FAIL=1
else
  echo "ok: no OVERLAID-AT-REGISTRATION markers remain under apps/spoke/"
fi

# ── 4. cloud-agnostic workload guard ─────────────────────────────────────────
# The hello workload may receive ONLY domain + subdomain — no ARNs, no region,
# no provider knowledge (the ADR-0005/0010 cloud-agnostic-workloads principle).
HELLO="$SPOKE_DIR/hello.yaml"
if [ -f "$HELLO" ]; then
  bad="$(grep -o '\.metadata\.annotations "k8-platform\.io/[a-z-]*"' "$HELLO" | sed 's/.*k8-platform\.io\///; s/"//' | sort -u | grep -v -e '^domain$' -e '^subdomain$' || true)"
  if [ -n "$bad" ]; then
    echo "FAIL[hello.yaml]: workload template references non-agnostic facts: $bad"; FAIL=1
  else
    echo "ok[hello.yaml]: workload receives only domain+subdomain (cloud-agnostic)"
  fi
else
  echo "FAIL: $HELLO missing"; FAIL=1
fi

[ "$FAIL" -eq 0 ] && echo "PASS: cluster-facts contract (consumer side)" || echo "FAILED"
exit "$FAIL"
