#!/usr/bin/env bash
# test_kubeconform_manifests.sh — SPEC-S6 lint.
#
# Two phases, both run on every invocation:
#
#   1. META-TEST — point kubeconform at each file in
#      tests/unit/fixtures/kubeconform/ and assert it gets the expected
#      verdict (pass / fail / skip-header). This guards the lint itself
#      against regression. See SPEC-S6 §6.
#
#   2. REPO AUDIT — scan every YAML under crossplane/, argocd/,
#      clusters/, policies/ (minus fixtures and any file with a
#      `# kubeconform-skip` header in its first 5 lines). Any
#      `statusInvalid` or `statusError` fails the test. `statusSkipped`
#      emits a `NOTICE:` and continues.
#
# For each scanned file the test runs kubeconform TWICE:
#
#   (a) Outer pass — validate the manifest in its raw shape (Composition,
#       ClusterPolicy, ExternalSecret, etc.) against the standard CRD
#       schemas in the store.
#
#   (b) Function-input pass — if the file contains a Crossplane v2
#       Composition, extract every spec.pipeline[].input and validate
#       it as a standalone document against the
#       `pt.fn.crossplane.io/v1beta1 Resources` schema. This is the
#       direct defense against PR #61 Bug 4 — the string-transform
#       missing-inner-type case. Without this step kubeconform sees
#       the input as opaque JSON inside the Composition CRD and
#       passes the file even when the transform is broken. SPEC-S6
#       §1, §5.3, §6.
#
# Schema store is at kubeconform-schemas/ and is pre-committed (CI
# cannot reach the cluster). Regenerate with
# `bash scripts/fetch-crds-for-kubeconform.sh` whenever a CRD pin
# changes — see SPEC-S6 §5.2 / §12.

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

# shellcheck disable=SC1091
. tests/unit/lib/test-helpers.sh

SCHEMA_LOCATION="kubeconform-schemas/{{ .Group }}/{{ .ResourceKind }}_{{ .ResourceAPIVersion }}.json"

# Pretty alias to flag emitted lines.
_emit_fail() { echo "  FAIL: $*"; }
_emit_notice() { echo "  NOTICE: $*"; }

# Hard requirement.
if ! command -v kubeconform >/dev/null 2>&1; then
  fail "kubeconform_binary_present" "kubeconform not on PATH (install per .github/workflows/unit-tests.yml)"
  summary
fi
if ! command -v python3 >/dev/null 2>&1; then
  fail "python3_present" "python3 required to parse kubeconform JSON output"
  summary
fi

# Skip header detection — first 5 lines, exact substring per SPEC-S6 §5.4.
has_skip_header() {
  head -n 5 "$1" 2>/dev/null | grep -q 'kubeconform-skip'
}

# Run kubeconform against a single file and print JSON to stdout only.
# Stderr (debug noise) is dropped because --output=json otherwise can
# emit log lines alongside the JSON document and break the parser.
run_kc() {
  local file="$1"
  kubeconform \
    --schema-location 'default' \
    --schema-location "$SCHEMA_LOCATION" \
    --ignore-missing-schemas \
    --verbose \
    --output json \
    "$file" 2>/dev/null
}

# Extract every Composition.spec.pipeline[].input as standalone YAML
# documents AND every input.resources[].base (the managed-resource
# template) so they can be validated as standalone kind+apiVersion
# documents. Writes to $2 and returns the count of extracted docs on
# stdout. Files with no Compositions write nothing and return 0.
#
# Extracting the .base templates is what catches PR #74 Bug 1 — the
# `forceOverwriteReplica: true` field lived inside the Composition's
# nested `input.resources[0].base.spec.forProvider` and is invisible
# to a check that only validates the Composition itself.
extract_pipeline_inputs() {
  local src="$1" dest="$2"
  python3 - "$src" "$dest" <<'PY'
import yaml, sys
src, dest = sys.argv[1], sys.argv[2]
docs_out = []
try:
    with open(src) as fh:
        for doc in yaml.safe_load_all(fh):
            if not doc:
                continue
            if doc.get("kind") != "Composition":
                continue
            comp_name = (doc.get("metadata") or {}).get("name", "unnamed")
            pipeline = (doc.get("spec") or {}).get("pipeline") or []
            for i, step in enumerate(pipeline):
                inp = step.get("input")
                if not inp:
                    continue
                inp.setdefault("metadata", {}).setdefault(
                    "name", f"{comp_name}-step-{i}",
                )
                docs_out.append(inp)
                # Also extract every resource.base as its own validatable
                # document — kubeconform validates it against the apiVersion
                # / kind declared in the base.
                resources = inp.get("resources") or []
                for j, res in enumerate(resources):
                    base = res.get("base")
                    if not isinstance(base, dict):
                        continue
                    if not base.get("apiVersion") or not base.get("kind"):
                        continue
                    # synthesize a name so kubeconform messages are useful
                    res_name = res.get("name", f"res-{j}")
                    base = dict(base)
                    base.setdefault("metadata", {}).setdefault(
                        "name", f"{comp_name}-{res_name}",
                    )
                    docs_out.append(base)
except Exception as e:
    sys.stderr.write(f"extract_pipeline_inputs: {src}: {e}\n")
    sys.exit(0)
if docs_out:
    with open(dest, "w") as fh:
        for d in docs_out:
            fh.write("---\n")
            yaml.safe_dump(d, fh)
print(len(docs_out))
PY
}

# Classify a kubeconform JSON output (read from stdin) into a list of
# statuses. Prints one line per resource: "<status>\t<kind>\t<name>\t<msg>".
#
# We invoke python3 via `python3 -c` (not a heredoc) because a
# `python3 - <<'PY' … PY` form would redirect python's stdin to the
# heredoc and silently lose the piped JSON. (Discovered while
# bootstrapping SPEC-S6 — symptoms were all-empty meta-test rows.)
classify_resources() {
  python3 -c '
import json, sys
raw = sys.stdin.read()
if not raw.strip():
    sys.exit(0)
try:
    doc = json.loads(raw)
except Exception as e:
    sys.stderr.write(f"could not parse kubeconform JSON: {e}\n")
    sys.stderr.write(raw + "\n")
    sys.exit(2)
for r in doc.get("resources", []):
    status = r.get("status", "?")
    kind = r.get("kind", "")
    name = r.get("name", "")
    msg = (r.get("msg") or "").replace("\t", " ").replace("\n", " ")
    print(f"{status}\t{kind}\t{name}\t{msg}")
'
}

# Run BOTH the outer pass and the function-input pass on $1. Emits
# tab-separated lines to stdout (same format as classify_resources).
classify_file() {
  local file="$1"
  local tmp_input
  tmp_input=$(mktemp --suffix=.yaml)
  trap "rm -f '$tmp_input'" RETURN

  # Outer pass
  run_kc "$file" | classify_resources

  # Function-input pass (only fires when extraction yields ≥1 input)
  local count
  count=$(extract_pipeline_inputs "$file" "$tmp_input" 2>/dev/null || echo 0)
  if [ "${count:-0}" -gt 0 ] && [ -s "$tmp_input" ]; then
    run_kc "$tmp_input" | classify_resources
  fi
  rm -f "$tmp_input"
}

# ── PHASE 1: META-TEST ─────────────────────────────────────────────────────

echo ""
echo "── meta-test: validating fixture cases ─────────────────────────"

# Helper: assert at least one statusInvalid|statusError row across BOTH
# the outer pass and the function-input pass.
assert_fixture_fails() {
  local file="$1" name="$2"
  local lines
  lines=$(classify_file "$file")
  if printf '%s\n' "$lines" | awk -F'\t' '$1=="statusInvalid" || $1=="statusError" {found=1} END{exit !found}'; then
    pass "$name"
  else
    fail "$name" "expected statusInvalid or statusError; got: $lines"
  fi
}

# Helper: assert ALL resources statusValid (function-input pass too).
# Acceptable: empty output (no resources to validate).
assert_fixture_all_valid() {
  local file="$1" name="$2"
  local lines bad
  lines=$(classify_file "$file")
  if [ -z "$lines" ]; then
    pass "$name"
    return
  fi
  bad=$(printf '%s\n' "$lines" | awk -F'\t' '$1!="statusValid" && $1!=""' || true)
  if [ -z "$bad" ]; then
    pass "$name"
  else
    fail "$name" "expected all statusValid; got bad rows: $bad"
  fi
}

# Helper: assert at least one statusSkipped row.
assert_fixture_has_skipped() {
  local file="$1" name="$2"
  local lines
  lines=$(classify_file "$file")
  if printf '%s\n' "$lines" | awk -F'\t' '$1=="statusSkipped" {found=1} END{exit !found}'; then
    pass "$name"
  else
    fail "$name" "expected statusSkipped; got: $lines"
  fi
}

FIXTURE_DIR="tests/unit/fixtures/kubeconform"

# 1. should_pass_composition.yaml — valid Composition + valid input
assert_fixture_all_valid \
  "$FIXTURE_DIR/should_pass_composition.yaml" \
  "fixture_should_pass_composition"

# 2. should_fail_string_transform_no_type.yaml — Bug 4 regression
#    (caught by the function-input pass, NOT the outer pass).
assert_fixture_fails \
  "$FIXTURE_DIR/should_fail_string_transform_no_type.yaml" \
  "fixture_should_fail_string_transform_no_type (PR #61 Bug 4 regression)"

# 3. should_fail_unknown_field.yaml — Bug 1 regression
assert_fixture_fails \
  "$FIXTURE_DIR/should_fail_unknown_field.yaml" \
  "fixture_should_fail_unknown_field (PR #74 Bug 1 regression)"

# 4. should_pass_claimspolicy.yaml — valid Kyverno ClusterPolicy
assert_fixture_all_valid \
  "$FIXTURE_DIR/should_pass_claimspolicy.yaml" \
  "fixture_should_pass_claimspolicy"

# 5. multi_doc_first_valid_second_invalid.yaml — must scan BOTH docs
assert_fixture_fails \
  "$FIXTURE_DIR/multi_doc_first_valid_second_invalid.yaml" \
  "fixture_multi_doc_scans_every_document"

# 5a. additionally verify both documents enumerated (not just one).
multi_lines=$(classify_file "$FIXTURE_DIR/multi_doc_first_valid_second_invalid.yaml")
multi_count=$(printf '%s\n' "$multi_lines" | grep -c $'\t' || true)
if [ "$multi_count" -ge 2 ]; then
  pass "fixture_multi_doc_enumerates_both_documents"
else
  fail "fixture_multi_doc_enumerates_both_documents" "only $multi_count resource(s) reported (expected ≥2)"
fi

# 6. should_pass_empty.yaml — empty file must not crash
assert_fixture_all_valid \
  "$FIXTURE_DIR/should_pass_empty.yaml" \
  "fixture_empty_file_no_crash"

# 7. should_pass_builtin_configmap.yaml — default schema location works
assert_fixture_all_valid \
  "$FIXTURE_DIR/should_pass_builtin_configmap.yaml" \
  "fixture_builtin_kind_uses_default_schema"

# 8. should_pass_unknown_crd.yaml — statusSkipped path is non-fatal
assert_fixture_has_skipped \
  "$FIXTURE_DIR/should_pass_unknown_crd.yaml" \
  "fixture_unknown_crd_emits_skipped_not_invalid"

# 9. should_pass_skip_header.yaml — the kubeconform-skip header
#    suppresses the otherwise-invalid body. The audit phase below is
#    what consumes the header; here we confirm the header is detected.
if has_skip_header "$FIXTURE_DIR/should_pass_skip_header.yaml"; then
  pass "fixture_skip_header_detected"
else
  fail "fixture_skip_header_detected" "header missing on fixture"
fi
if has_skip_header "$FIXTURE_DIR/should_pass_composition.yaml"; then
  fail "fixture_pass_composition_does_NOT_have_skip_header" "unexpected header"
else
  pass "fixture_pass_composition_does_NOT_have_skip_header"
fi

# ── PHASE 2: REPO AUDIT ────────────────────────────────────────────────────

echo ""
echo "── repo audit: scanning crossplane/ argocd/ clusters/ policies/ ──"

# Path-exclude:
#   - tests/*                — chainsaw scenario YAML uses chainsaw-test schema, not k8s
#   - */render-fixtures/*    — SPEC-S9 `crossplane render` inputs are XR YAMLs in
#                              the post-promotion shape (carry spec.claimRef, which
#                              the XRD schema correctly forbids on user-authored
#                              input — the Crossplane composite controller sets it
#                              when promoting a claim). These are offline render
#                              fixtures, not authored cluster manifests, so they
#                              are out of scope for this lint by design rather
#                              than via per-file skip headers.
AUDIT_FILES=()
while IFS= read -r -d '' f; do
  AUDIT_FILES+=("$f")
done < <(find crossplane/ argocd/ clusters/ policies/ \
  \( -name '*.yaml' -o -name '*.yml' \) \
  -not -path 'tests/*' \
  -not -path '*/render-fixtures/*' \
  -print0 2>/dev/null)

audit_fail_count=0
audit_skip_header_count=0
audit_notice_count=0
audit_valid_count=0

for f in "${AUDIT_FILES[@]}"; do
  if has_skip_header "$f"; then
    _emit_notice "kubeconform-skip header honored: $f"
    audit_skip_header_count=$((audit_skip_header_count + 1))
    continue
  fi
  lines=$(classify_file "$f")
  if [ -z "$lines" ]; then
    continue
  fi
  while IFS=$'\t' read -r status kind name msg; do
    [ -z "$status" ] && continue
    case "$status" in
      statusValid)
        audit_valid_count=$((audit_valid_count + 1))
        ;;
      statusSkipped)
        _emit_notice "schema missing for ${kind} ${name} in ${f}"
        audit_notice_count=$((audit_notice_count + 1))
        ;;
      statusInvalid|statusError)
        _emit_fail "${f}: ${kind} ${name} — ${msg}"
        audit_fail_count=$((audit_fail_count + 1))
        ;;
      *)
        _emit_fail "${f}: ${kind} ${name} — unexpected status '${status}': ${msg}"
        audit_fail_count=$((audit_fail_count + 1))
        ;;
    esac
  done <<< "$lines"
done

echo ""
echo "── repo audit summary:"
echo "     ${#AUDIT_FILES[@]} files scanned"
echo "     ${audit_valid_count} resources statusValid (outer + function-input passes)"
echo "     ${audit_notice_count} statusSkipped NOTICEs (no schema in store)"
echo "     ${audit_skip_header_count} files honored kubeconform-skip header"
echo "     ${audit_fail_count} statusInvalid / statusError"

if [ "$audit_fail_count" -gt 0 ]; then
  fail "repo_audit_zero_invalid_or_error" "see FAIL lines above"
else
  pass "repo_audit_zero_invalid_or_error"
fi

summary
