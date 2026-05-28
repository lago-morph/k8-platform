#!/usr/bin/env bash
# pre-chainsaw-audit.sh — implementation of `pre-dispatch-static-audit` skill
# (SKILL-SPEC-3a7d2e9f1c). Invoke BEFORE dispatching `chainsaw.yml` to catch
# the recurring bug classes that have surfaced in prior runs.
#
# Per AGENTS.md §6.13. Each check is a one-line grep; the full audit runs
# in seconds. Skipping it costs ~5-15 minutes per chainsaw iteration per
# missed bug class.
#
# Bug classes covered (each as one numbered Check):
#   A: non-ASCII (em-dash etc.) in tag-bound `description:` / `Description:`
#      values (AWS Resource Groups Tagging rejects — auto-003 Strike 1)
#   B: bash-only constructs (`set -o pipefail`, `[[ `, `<<<`, `((`,
#      process substitution) inside chainsaw `script.content:` blocks
#      (chainsaw runs scripts under /bin/sh — auto-003 Strike 3)
#   C: chainsaw `status.conditions:` asserts on v2 XRs that don't list
#      all 3 conditions (Synced + Ready + Responsive — auto-003 Strike 2)
#   D: `($namespace)` literal in `apply.resource.metadata.namespace`
#      (chainsaw pre-substitution validation rejects per RFC 1123 —
#      auto-003 PR-T3 Strike 1)
#   E: chainsaw `assert: file: expected/*.yaml` goldens whose
#      metadata.namespace is missing or is the binding `($namespace)`
#      (chainsaw `assert: file:` searches the per-test namespace by
#      default — auto-003 PR-T3 Strike 2)
#   F: golden `Description:` / `description:` text not matching the
#      corresponding scenario's XR `spec.description` (the Composition
#      patches XR.spec.description into MR.spec.forProvider.tags.Description
#      — auto-003 PR-T3 Strike 4)
#
# Exit 0 if all checks pass (safe to dispatch). Exit 1 if any check
# fails (fix first, re-run).

set -uo pipefail
cd "$(dirname "$0")/.."   # repo root

# ---------------------------------------------------------------------------
# Colours / output helpers
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'
else
  R=''; G=''; Y=''; B=''; N=''
fi

OVERALL_FAIL=0

pass() { printf "  ${G}✓${N} %s\n" "$1"; }
fail() {
  printf "  ${R}✗${N} %s\n" "$1"
  if [ -n "${2:-}" ]; then
    printf "    %s\n" "$2"
  fi
  OVERALL_FAIL=1
}

heading() { printf "\n${B}== %s ==${N}\n" "$1"; }

# ---------------------------------------------------------------------------
# Scope: files this audit reads. Cluster-bound paths + chainsaw scenarios.
# ---------------------------------------------------------------------------
SCAN_PATHS=(
  tests/chainsaw
  crossplane/claims
  crossplane/xrds
  crossplane/compositions
  clusters
  policies
  tests/integration
)

# Filter to paths that actually exist (so the script is safe to run from a
# partial checkout or a refactored layout).
EXISTING_PATHS=()
for p in "${SCAN_PATHS[@]}"; do
  [ -d "$p" ] && EXISTING_PATHS+=("$p")
done

if [ "${#EXISTING_PATHS[@]}" -eq 0 ]; then
  fail "no scan paths exist" "audit is a no-op; check that you are at the repo root"
  exit 1
fi

# Strip YAML comments before content matching: lines starting with `#` after
# optional leading whitespace. Inline `# comment` after a value is preserved
# (a literal `#` inside a quoted string is content, not a comment, and YAML
# specifies '#' only starts a comment when preceded by whitespace; for the
# audit's purposes the simple line-leader strip is good enough).
strip_yaml_comments() {
  sed 's/^[[:space:]]*#.*$//'
}

# ---------------------------------------------------------------------------
# Check A — non-ASCII in tag-bound description fields
# ---------------------------------------------------------------------------
heading "Check A: non-ASCII in tag-bound description fields"
a_files=$(
  {
    find "${EXISTING_PATHS[@]}" -name '*.yaml' -type f 2>/dev/null
    find "${EXISTING_PATHS[@]}" -name '*.sh'   -type f 2>/dev/null
  } | sort -u
)
a_hits=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  bad=$(strip_yaml_comments < "$f" \
        | grep -nE '^[[:space:]]*(description|Description):[[:space:]]+' \
        | LC_ALL=C grep -nP '[\x80-\xff]' \
        || true)
  if [ -n "$bad" ]; then
    fail "non-ASCII in description: ${f}" "$(echo "$bad" | head -3)"
    a_hits=$((a_hits + 1))
  fi
done <<< "$a_files"
[ "$a_hits" -eq 0 ] && pass "all 'description:' / 'Description:' fields are ASCII-clean"

# ---------------------------------------------------------------------------
# Check B — bash-isms in chainsaw script.content blocks
# ---------------------------------------------------------------------------
heading "Check B: bash-isms in chainsaw script.content blocks"
b_files=$(find tests/chainsaw -name 'chainsaw-test.yaml' -type f 2>/dev/null | sort)
b_hits=0
b_pattern='set[[:space:]]+-[a-z]*o[a-z]*[[:space:]]+pipefail|^\s*if[[:space:]]*\[\[|[[:space:]]\[\[[[:space:]]|<<<|^\s*\(\(|[[:space:]]<\([[:space:]]'
while IFS= read -r f; do
  [ -z "$f" ] && continue
  bad=$(strip_yaml_comments < "$f" | grep -nE "$b_pattern" || true)
  if [ -n "$bad" ]; then
    fail "bash-ism in script.content: ${f}" "$(echo "$bad" | head -3)"
    b_hits=$((b_hits + 1))
  fi
done <<< "$b_files"
[ "$b_hits" -eq 0 ] && pass "all chainsaw script.content blocks are POSIX-portable"

# ---------------------------------------------------------------------------
# Check C — chainsaw v2 XR status.conditions asserts list all 3 conditions
# ---------------------------------------------------------------------------
heading "Check C: chainsaw v2 XR conditions asserts list all 3 (Synced, Ready, Responsive)"
c_files=$(find tests/chainsaw -name 'chainsaw-test.yaml' -type f 2>/dev/null | sort)
c_hits=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  # Only check files that assert XPlatform* status conditions.
  if ! grep -qE '^[[:space:]]*kind:[[:space:]]+XPlatform' "$f"; then
    continue
  fi
  if ! grep -qE '^[[:space:]]*conditions:[[:space:]]*$' "$f"; then
    continue
  fi
  for t in Synced Ready Responsive; do
    if ! grep -qE "^[[:space:]]*-[[:space:]]+type:[[:space:]]+${t}([[:space:]]|$)" "$f"; then
      fail "missing 'type: ${t}' in v2 XR conditions: ${f}" \
        "v2 XRs carry 3 conditions (Synced, Ready, Responsive); listing fewer fails with 'lengths of slices don't match'"
      c_hits=$((c_hits + 1))
      break
    fi
  done
done <<< "$c_files"
[ "$c_hits" -eq 0 ] && pass "all chainsaw v2 XR conditions asserts list all 3 condition types"

# ---------------------------------------------------------------------------
# Check D — ($namespace) literal in apply.resource.metadata.namespace
# ---------------------------------------------------------------------------
heading "Check D: '(\$namespace)' literal in apply.resource.metadata.namespace"
d_files=$(find tests/chainsaw -name 'chainsaw-test.yaml' -type f 2>/dev/null | sort)
d_hits=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  # Find any `namespace: ($namespace)` that is inside an apply block (rough
  # heuristic: the scenario uses `apply:` somewhere; we flag ANY ($namespace)
  # outside the catch block's describe/events context. The catch block is
  # allowed because chainsaw substitutes there.
  # Conservative: only flag namespace: ($namespace) lines that appear within
  # the first 60% of the file (apply steps are typically before catch).
  total_lines=$(wc -l < "$f")
  cutoff=$(( total_lines * 6 / 10 ))
  [ "$cutoff" -lt 1 ] && cutoff=1
  bad=$(head -n "$cutoff" "$f" \
        | grep -nE '^[[:space:]]+namespace:[[:space:]]+\(\$namespace\)[[:space:]]*$' \
        || true)
  if [ -n "$bad" ]; then
    fail "(\$namespace) literal in apply step's metadata.namespace: ${f}" \
      "chainsaw schema validates metadata.namespace against RFC 1123 pre-substitution and rejects '(\$namespace)'. Use 'namespace: default' instead. Line(s):$'\n'$(echo "$bad" | head -3)"
    d_hits=$((d_hits + 1))
  fi
done <<< "$d_files"
[ "$d_hits" -eq 0 ] && pass "no '(\$namespace)' literal in apply step metadata.namespace"

# ---------------------------------------------------------------------------
# Check E — goldens specify metadata.namespace (not missing, not binding)
# ---------------------------------------------------------------------------
heading "Check E: goldens carry explicit metadata.namespace"
e_files=$(find tests/chainsaw -path '*/expected/*.yaml' -type f 2>/dev/null | sort)
e_hits=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  # Golden must either have `metadata.namespace: <literal>` or `metadata.namespace: ($namespace)`.
  # If `metadata.namespace: ($namespace)`, that's a fail (chainsaw assert: file: doesn't
  # substitute bindings the same way as inline resource asserts).
  ns_line=$(grep -nE '^[[:space:]]*namespace:[[:space:]]+' "$f" | head -1 || true)
  if [ -z "$ns_line" ]; then
    fail "golden missing metadata.namespace: ${f}" \
      "chainsaw 'assert: file:' searches the per-test namespace by default; add 'metadata.namespace: default' (or wherever the MR lives)"
    e_hits=$((e_hits + 1))
    continue
  fi
  if echo "$ns_line" | grep -qE 'namespace:[[:space:]]+\(\$namespace\)[[:space:]]*$'; then
    fail "golden uses '(\$namespace)' binding (won't substitute in assert: file:): ${f}" \
      "use literal 'namespace: default' (or whichever namespace the MR lives in)"
    e_hits=$((e_hits + 1))
  fi
done <<< "$e_files"
[ "$e_hits" -eq 0 ] && pass "all chainsaw goldens carry explicit metadata.namespace"

# ---------------------------------------------------------------------------
# Check F — golden Description value matches the corresponding scenario's XR description
# ---------------------------------------------------------------------------
heading "Check F: golden Description matches scenario XR description"
f_hits=0
# Map: for each platform-secret/<N>/expected/asm-secret.yaml, the scenario
# is platform-secret/<N>/chainsaw-test.yaml and the XR description is the
# value of `spec.description:`.
for golden in $(find tests/chainsaw/platform-secret -path '*/expected/asm-secret.yaml' -type f 2>/dev/null | sort); do
  dir=$(dirname "$golden")
  scenario="$(dirname "$dir")/chainsaw-test.yaml"
  [ -f "$scenario" ] || continue
  xr_desc=$(grep -nE '^[[:space:]]+description:[[:space:]]+' "$scenario" | head -1 | sed -E 's/^[^"]*"([^"]*)".*$/\1/; s/^[^:]*:[[:space:]]+([^[:space:]].*)$/\1/' | head -1)
  golden_desc=$(grep -nE '^[[:space:]]+Description:[[:space:]]+' "$golden" | head -1 | sed -E 's/^[^"]*"([^"]*)".*$/\1/; s/^[^:]*:[[:space:]]+([^[:space:]].*)$/\1/' | head -1)
  if [ -z "$xr_desc" ] || [ -z "$golden_desc" ]; then
    continue
  fi
  if [ "$xr_desc" != "$golden_desc" ]; then
    fail "golden Description != scenario XR description" \
      "scenario: ${scenario} → \"${xr_desc}\"; golden: ${golden} → \"${golden_desc}\""
    f_hits=$((f_hits + 1))
  fi
done
[ "$f_hits" -eq 0 ] && pass "all goldens' Description match the scenario's XR description"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
if [ "$OVERALL_FAIL" -eq 0 ]; then
  printf "${G}${B}AUDIT GREEN${N} — safe to dispatch chainsaw.\n"
  exit 0
else
  printf "${R}${B}AUDIT RED${N} — fix the above before dispatching chainsaw.\n"
  printf "${Y}Per AGENTS.md §6.13, dispatching with any of these unfixed is expected to fail.${N}\n"
  exit 1
fi
