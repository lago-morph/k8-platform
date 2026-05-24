#!/usr/bin/env bash
# Lint: every Composition pipeline patch transform of type=string MUST
# specify .string.type (Format | Convert | TrimPrefix | TrimSuffix |
# Regexp | Join).
#
# Bug-of-record: phase-2-diagnose run 26348711132 — composite XR
# stuck Synced=False with reason ReconcileError:
#   "cannot compose resources: pipeline step \"patch-and-transform\"
#    returned a fatal result: invalid Function input:
#    resources[0].patches[0].transforms[0].string.type: Required value:
#    string transform type is required"
# Same bug existed in 9 places across crossplane/compositions/
# platform-secret.yaml and platform-cluster.yaml. The XR validator
# rejects the entire composition before ANY resource is rendered, so
# every claim against either XRD stays Ready=False forever and no
# managed AWS resource is ever created. Silent on the apply path
# (XRD/Composition both Established and Synced); only surfaces when a
# claim is applied and the composite tries to render.
#
# This lint walks every Composition file and asserts:
#   for each pipeline[].input.resources[].patches[].transforms[]:
#     if .type == "string": .string.type must be set
#
# Implemented in python because yq lacks the nested-list filtering
# expressiveness we need without a regex hack.

set -uo pipefail
cd "$(dirname "$0")/../.."

# shellcheck disable=SC1091
. tests/lib/assert.sh

python3 - <<'PY'
import pathlib, sys, yaml

bad = []  # (file, resource_name, patch_index, transform_index)

for path in sorted(pathlib.Path("crossplane/compositions").glob("*.yaml")):
    doc = yaml.safe_load(path.read_text())
    if not doc or doc.get("kind") != "Composition":
        continue
    for step in doc.get("spec", {}).get("pipeline", []) or []:
        resources = (step.get("input", {}) or {}).get("resources", []) or []
        for res in resources:
            rname = res.get("name", "<unnamed>")
            for pi, patch in enumerate(res.get("patches", []) or []):
                for ti, tr in enumerate(patch.get("transforms", []) or []):
                    if tr.get("type") != "string":
                        continue
                    inner = tr.get("string", {}) or {}
                    if "type" not in inner:
                        bad.append((path.name, rname, pi, ti, sorted(inner.keys())))

if bad:
    for f, r, pi, ti, keys in bad:
        print(f"  FAIL: {f} resource={r!r} patches[{pi}].transforms[{ti}]: "
              f"string transform missing .string.type (has keys: {keys})")
    sys.exit(1)
sys.exit(0)
PY
rc=$?
if [ "$rc" -eq 0 ]; then
  _pass "composition_string_transforms_have_type"
else
  _fail "composition_string_transforms_have_type" "see PY output above"
fi

assert_summary
