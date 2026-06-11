#!/usr/bin/env bash
# Gates the cluster-facts contract (ADR-0010) BIDIRECTIONALLY:
#   consumer side — the spoke ApplicationSets may reference ONLY the
#     contract's annotation/label keys on the cluster Secret;
#   producer side (ADR-0010 PR-2 / OI-2026-06-07-1) — the xspokeaccess
#     Composition's spoke-cluster-secret Object must emit EXACTLY the
#     contract keys (no missing fact, no extra surface), with every patch
#     into the Secret manifest carrying policy.fromFieldPath: Required
#     (the complete-or-absent guarantee), and the registration name
#     following <subdomain>-spoke (the AppProject allowlist contract).
# Every contract key must be documented in the ADR.
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
ANNOTATION_KEYS="domain subdomain certificate-arn external-dns-role-arn region eso-role-arn"
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

# ── 2b. PRODUCER: the Composition emits exactly the contract keys ───────────
COMP="$ROOT/crossplane/compositions/xspokeaccess.yaml"
if [ ! -f "$COMP" ]; then
  echo "FAIL: $COMP missing (the producer half has no source)"; FAIL=1
else
  # annotation keys the spoke-cluster-secret Object patches write
  PRODUCED_ANN=$(grep -o 'manifest\.metadata\.annotations\[k8-platform\.io/[a-z-]*\]' "$COMP" \
    | sed 's/.*k8-platform\.io\///; s/\]//' | sort -u)
  # label keys: patched ones + the base-manifest literals
  PRODUCED_LBL=$( (grep -o 'manifest\.metadata\.labels\[k8-platform\.io/[a-z-]*\]' "$COMP" \
      | sed 's/.*k8-platform\.io\///; s/\]//'; \
    yq -r '.spec.pipeline[] | select(.functionRef.name=="function-patch-and-transform")
           | .input.resources[] | select(.name=="spoke-cluster-secret")
           | .base.spec.forProvider.manifest.metadata.labels
           | keys | .[]' "$COMP" 2>/dev/null \
      | grep '^k8-platform\.io/' | sed 's/k8-platform\.io\///') | sort -u)

  # bidirectional: produced == contract, both directions
  for k in $ANNOTATION_KEYS; do
    echo "$PRODUCED_ANN" | grep -qx "$k" \
      && echo "ok[producer]: contract annotation '$k' emitted" \
      || { echo "FAIL[producer]: contract annotation '$k' NOT emitted by the Composition"; FAIL=1; }
  done
  for k in $PRODUCED_ANN; do
    # shellcheck disable=SC2086
    in_list "$k" $ANNOTATION_KEYS \
      || { echo "FAIL[producer]: Composition emits annotation k8-platform.io/$k — NOT in the contract"; FAIL=1; }
  done
  for k in $LABEL_KEYS; do
    echo "$PRODUCED_LBL" | grep -qx "$k" \
      && echo "ok[producer]: contract label '$k' emitted" \
      || { echo "FAIL[producer]: contract label '$k' NOT emitted by the Composition"; FAIL=1; }
  done
  for k in $PRODUCED_LBL; do
    # shellcheck disable=SC2086
    in_list "$k" $LABEL_KEYS \
      || { echo "FAIL[producer]: Composition emits label k8-platform.io/$k — NOT in the contract"; FAIL=1; }
  done

  # complete-or-absent: every patch on the Secret Object is Required
  SC_SEL='.spec.pipeline[] | select(.functionRef.name=="function-patch-and-transform") | .input.resources[] | select(.name=="spoke-cluster-secret")'
  P_TOTAL=$(yq -r "${SC_SEL} | .patches | length" "$COMP")
  P_REQ=$(yq -r "${SC_SEL} | .patches[] | select(.policy.fromFieldPath==\"Required\") | .toFieldPath" "$COMP" | grep -vc '^---$')
  if [ "$P_TOTAL" -gt 0 ] && [ "$P_TOTAL" = "$P_REQ" ]; then
    echo "ok[producer]: all $P_TOTAL Secret patches are Required (complete-or-absent)"
  else
    echo "FAIL[producer]: $P_REQ/$P_TOTAL Secret patches are Required — a partial Secret write is possible"; FAIL=1
  fi

  # registration name contract: <subdomain>-spoke
  N_FMT=$(yq -r "${SC_SEL} | .patches[] | select(.toFieldPath==\"spec.forProvider.manifest.metadata.name\") | .transforms[0].string.fmt" "$COMP")
  if [ "$N_FMT" = "%s-spoke" ]; then
    echo "ok[producer]: registration name fmt is %s-spoke (AppProject allowlist contract)"
  else
    echo "FAIL[producer]: registration name fmt '$N_FMT' != %s-spoke — generated destinations would be rejected by the platform-spoke AppProject"; FAIL=1
  fi
fi

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

[ "$FAIL" -eq 0 ] && echo "PASS: cluster-facts contract (bidirectional: consumer + producer)" || echo "FAILED"
exit "$FAIL"
