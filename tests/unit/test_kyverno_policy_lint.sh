#!/usr/bin/env bash
# Unit tests for policies/audit/*.yaml — Kyverno ClusterPolicy syntactic
# health checks that catch authoring bugs before Kyverno's admission
# webhook rejects them at apply time (which costs a full management
# apply round).
#
# Today: detect invalid JMESPath literals — specifically, empty
# backticks (`` ``), which are a syntax error JMESPath surfaces as
# "unexpected end of JSON input". This is exactly the bug class that
# broke phase 1 apply-and-verify against fresh account 309191981509 —
# Kyverno accepted 7 policies, then rejected 03-ingress-managed-by-
# external-dns with that error, taking down the whole apply step.
#
# This test is a pure-static lint — no Kyverno binary required, runs
# locally in <1s.

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

# shellcheck disable=SC1091
. tests/lib/assert.sh

POLICY_DIRS=("policies/audit" "crossplane/policies")

# ---- 1. No empty-backtick JMESPath literals in any audit policy ---------
#
# Defends contract: every backticked JMESPath literal (`...`) must
# contain valid JSON. Empty `` is invalid and Kyverno rejects the
# policy at admission time (validate-policy.kyverno.svc).
#
# Bug-of-record: phase 1 apply 2026-05-23 failed with
# "policy contains invalid variables: ... invalid JMESPath query
# request.object.spec.rules[].host || `` | to_string(@): unexpected
# end of JSON input".
#
# Implementation: scan every {{ ... }} expression in the YAML and
# inside each, scan for backtick pairs. If any backtick pair is empty
# OR contains content that doesn't parse as JSON, fail.
python3 - <<'PY'
import pathlib, re, json, sys

policy_dirs = [pathlib.Path("policies/audit"), pathlib.Path("crossplane/policies")]
bad = []  # (file, lineno, snippet)

# Match {{ ... }} substitution blocks (greedy on inner). Then within,
# find every backticked literal.
mustache_re = re.compile(r"\{\{(.*?)\}\}")
backtick_re = re.compile(r"`([^`]*)`")

for policy_dir in policy_dirs:
  if not policy_dir.exists():
    continue
  for yaml_path in sorted(policy_dir.glob("*.yaml")):
    text = yaml_path.read_text()
    for lineno, line in enumerate(text.splitlines(), start=1):
        for m in mustache_re.finditer(line):
            expr = m.group(1)
            for bt in backtick_re.finditer(expr):
                literal = bt.group(1)
                if literal.strip() == "":
                    bad.append((yaml_path.name, lineno, line.strip(), "empty backtick literal"))
                    continue
                try:
                    json.loads(literal)
                except Exception as e:
                    bad.append((yaml_path.name, lineno, line.strip(), f"not valid JSON: {e}"))

if bad:
    for f, n, snip, why in bad:
        print(f"  FAIL: {f}:{n}: {why}")
        print(f"        {snip}")
    sys.exit(1)
sys.exit(0)
PY
rc=$?
if [ "$rc" -eq 0 ]; then
  _pass "no_empty_or_invalid_jmespath_backtick_literals"
else
  _fail "no_empty_or_invalid_jmespath_backtick_literals" "see PY output above"
fi

# ---- 2. Every policy has a metadata.name (cheap structural check) -------
#
# Defends contract: ClusterPolicy without a name is rejected by
# Kubernetes. Catches accidental delete/rename mishaps that would
# look like a "policy applied" but in fact nothing landed.
for dir in "${POLICY_DIRS[@]}"; do
  [ -d "$dir" ] || continue
  for yaml_path in "$dir"/*.yaml; do
    [ -f "$yaml_path" ] || continue
    kind=$(yq -r '.kind' "$yaml_path" 2>/dev/null)
    [ "$kind" = "ClusterPolicy" ] || continue
    name=$(yq -r '.metadata.name' "$yaml_path" 2>/dev/null)
    base=$(basename "$yaml_path")
    if [ -n "$name" ] && [ "$name" != "null" ]; then
      _pass "policy_has_name:$base"
    else
      _fail "policy_has_name:$base" "no .metadata.name on the ClusterPolicy doc"
    fi
  done
done

# ---- 3. Every policy declares an explicit validationFailureAction -------
#
# Defends contract: per phase-1 design, all audit policies must run
# with validationFailureAction == Audit (not Enforce). A silently-
# missing field defaults differently across Kyverno versions and a
# policy author who forgets it might accidentally start blocking
# admission. Pins it explicitly per policy.
for dir in "${POLICY_DIRS[@]}"; do
  [ -d "$dir" ] || continue
  for yaml_path in "$dir"/*.yaml; do
    [ -f "$yaml_path" ] || continue
    kind=$(yq -r '.kind' "$yaml_path" 2>/dev/null)
    [ "$kind" = "ClusterPolicy" ] || continue
    action=$(yq -r '.spec.validationFailureAction' "$yaml_path" 2>/dev/null)
    base=$(basename "$yaml_path")
    if [ "$action" = "Audit" ]; then
      _pass "policy_action_audit:$base"
    else
      _fail "policy_action_audit:$base" "validationFailureAction=$action (expected: Audit)"
    fi
  done
done

# ---- 4. Drift-defense fields explicit on every ClusterPolicy -----------
#
# Defends contract: Kyverno's admission/background controllers inject
# defaults for spec.background, spec.admission, and the autogen rules
# annotation when these are absent from the applied YAML. ArgoCD then
# sees the live object as drifted from git and reports OutOfSync on
# every sync. Bug-of-record: phase-2-diagnose run 26351930369 — the
# `crossplane-resources` ArgoCD App stays OutOfSync because
# ClusterPolicy/platform-secret-namespace-allowed has these fields
# injected by Kyverno on every reconcile.
#
# Scope: ArgoCD-synced policies only (crossplane/policies/). The
# policies/audit/ directory is kubectl-applied once by Terraform during
# management bring-up and is not tracked by ArgoCD, so drift there is
# invisible — no point flagging it.
#
# Note: this lint only defends against the KNOWN drift fields below.
# New Kyverno releases may inject additional defaults; the loop-closer
# remains a `phase-2-diagnose` run that confirms crossplane-resources
# reaches sync=Synced.
for dir in "crossplane/policies"; do
  [ -d "$dir" ] || continue
  for yaml_path in "$dir"/*.yaml; do
    [ -f "$yaml_path" ] || continue
    kind=$(yq -r '.kind' "$yaml_path" 2>/dev/null)
    [ "$kind" = "ClusterPolicy" ] || continue
    base=$(basename "$yaml_path")

    bg=$(yq -r '.spec.background' "$yaml_path" 2>/dev/null)
    if [ "$bg" = "true" ] || [ "$bg" = "false" ]; then
      _pass "policy_background_explicit:$base"
    else
      _fail "policy_background_explicit:$base" "spec.background is $bg (must be set to true|false to prevent Kyverno default-injection drift)"
    fi

    adm=$(yq -r '.spec.admission' "$yaml_path" 2>/dev/null)
    if [ "$adm" = "true" ] || [ "$adm" = "false" ]; then
      _pass "policy_admission_explicit:$base"
    else
      _fail "policy_admission_explicit:$base" "spec.admission is $adm (must be set to true|false to prevent Kyverno default-injection drift)"
    fi

    autogen=$(yq -r '.metadata.annotations["pod-policies.kyverno.io/autogen-controllers"]' "$yaml_path" 2>/dev/null)
    if [ -n "$autogen" ] && [ "$autogen" != "null" ]; then
      _pass "policy_autogen_annotation_set:$base"
    else
      _fail "policy_autogen_annotation_set:$base" "annotation pod-policies.kyverno.io/autogen-controllers is unset (Kyverno autogen will inject Pod-controller rules causing ArgoCD drift; set to 'none' for non-Pod kinds)"
    fi
  done
done

assert_summary
