#!/usr/bin/env bash
# Regression guard (run 27072199866): chainsaw scenarios that provision live
# cloud resources must NOT run in the per-PR kind-only chainsaw matrix (the kind
# harness has no provider-aws-rds etc., so they fail fast and red every push).
# The contract: such a scenario marks itself with the literal "REAL-AWS /
# NIGHTLY" header in its chainsaw-test.yaml, and tests/chainsaw/run.sh excludes
# any so-marked scenario from the default run unless CHAINSAW_INCLUDE_REALAWS=1.
# This test fails if either side of that contract is missing.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-helpers.sh"

RUN_SH="$HERE/../../tests/chainsaw/run.sh"
CHAINSAW_DIR="$HERE/../../tests/chainsaw"
[ -f "$RUN_SH" ] || { echo "missing $RUN_SH"; exit 2; }

# 1. run.sh implements the opt-in exclusion.
if grep -q 'CHAINSAW_INCLUDE_REALAWS' "$RUN_SH" && grep -q 'REAL-AWS / NIGHTLY' "$RUN_SH"; then
  pass "run.sh gates REAL-AWS/NIGHTLY scenarios behind CHAINSAW_INCLUDE_REALAWS"
else
  fail "run.sh must exclude REAL-AWS/NIGHTLY scenarios by default" \
       "they provision live cloud resources the kind harness can't support and red every push."
fi

# 2. The known live scenarios (xdatabase RDS create/delete) carry the marker so
#    the exclusion actually catches them.
for s in xdatabase/01-claim-creates-rds xdatabase/02-deletion-cleanup; do
  f="$CHAINSAW_DIR/$s/chainsaw-test.yaml"
  if [ -f "$f" ] && grep -q 'REAL-AWS / NIGHTLY' "$f"; then
    pass "scenario $s is marked REAL-AWS / NIGHTLY"
  elif [ -f "$f" ]; then
    fail "scenario $s must carry the REAL-AWS / NIGHTLY header" \
         "it provisions a live RDS instance; without the marker run.sh runs it in the kind matrix and it fails."
  fi
done

# 3. A kind-only scenario must NOT carry the marker (else it'd be wrongly skipped).
f="$CHAINSAW_DIR/xdatabase/00-xrd-establishes/chainsaw-test.yaml"
if [ -f "$f" ] && grep -q 'REAL-AWS / NIGHTLY' "$f"; then
  fail "xdatabase/00-xrd-establishes must NOT be marked REAL-AWS (it is kind-only)" \
       "marking it would exclude the kind-only XRD-establishes coverage from per-PR runs."
else
  pass "xdatabase/00-xrd-establishes runs in the kind matrix (not marked real-AWS)"
fi

summary
