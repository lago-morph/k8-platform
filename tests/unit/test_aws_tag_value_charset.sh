#!/usr/bin/env bash
# Every value that can land in an AWS tag must use only the characters the
# AWS tagging services accept: letters, numbers, spaces, and + - = . _ : / @
#
# The bug class (clean build #4, 2026-07-05 — third live defect): the
# platform-secret Composition patches XR spec.description into the ASM
# container's Description tag. The two committed keycloak XPlatformSecret
# descriptions contained PARENTHESES → CreateSecret failed
# "InvalidRequestException: Request rejected by the downstream tagging
# service. Please check that you're only using allowed characters." — the
# whole material chain sat Unready on the live hub, with spoke-keycloak
# Degraded behind the missing admin Secret. Chainsaw passed twice the same
# day because its scenario descriptions happen to be paren-free: the
# committed XRs never had a live producer before the keycloak-secrets
# Application landed. Sibling of the em-dash class in
# scripts/pre-chainsaw-audit.sh Check A (which scans chainsaw files);
# THIS lint scans every committed XR the live platform will actually
# reconcile, plus static tag values in Compositions.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-helpers.sh"
require_tool yq

ROOT="$HERE/../.."

out="$(python3 - "$ROOT" <<'PYEOF'
import os, sys, glob, subprocess, json, re

root = sys.argv[1]
# AWS tag-value charset (Resource Groups Tagging / Secrets Manager).
ok = re.compile(r'^[A-Za-z0-9 +\-=._:/@]*$')
violations = []

def check(rel, what, val):
    if val and not ok.match(val):
        bad = sorted(set(ch for ch in val if not ok.match(ch)))
        violations.append(f"TAG-UNSAFE {rel}: {what} = '{val}' (disallowed: {bad})")

# 1. Every committed XR document with a spec.description (any kind whose
#    Composition may tag it — scan broadly; a false positive costs a
#    rename, a false negative costs a live build).
scan_globs = [
    "platform-services/**/*.yaml",
    "crossplane/claims/*.yaml",
    "crossplane/xrds/*/render-fixtures/input.yaml",
    "tests/chainsaw/**/chainsaw-test.yaml",
]
files = []
for g in scan_globs:
    files.extend(glob.glob(os.path.join(root, g), recursive=True))

for f in sorted(set(files)):
    rel = os.path.relpath(f, root)
    r = subprocess.run(
        ["yq", "eval-all", "-o=json", "-I0",
         '{"kind": .kind, "name": (.metadata.name // ""), "desc": (.spec.description // "")}',
         f],
        capture_output=True, text=True, timeout=30)
    if r.returncode != 0:
        continue  # non-k8s yaml (helm values etc.) — skip silently
    for line in r.stdout.splitlines():
        line = line.strip()
        if not line or line == "null":
            continue
        try:
            d = json.loads(line)
        except Exception:
            continue
        if d.get("desc"):
            check(rel, f'{d.get("kind")}/{d.get("name")} spec.description', d["desc"])
    # chainsaw scenario XRs are nested under steps; scan raw description lines too
    if "chainsaw-test.yaml" in f:
        for i, raw in enumerate(open(f).read().splitlines(), 1):
            m = re.match(r'\s*description:\s*"(.*)"\s*$', raw)
            if m:
                check(rel, f"line {i} description", m.group(1))

# 2. Static tag values in Compositions (spec...tags maps).
for f in sorted(glob.glob(os.path.join(root, "crossplane", "compositions", "*.yaml"))):
    rel = os.path.relpath(f, root)
    # yq pass over every resources[].base...tags map
    r = subprocess.run(
        ["yq", "eval-all", "-o=json", "-I0",
         '[.spec.pipeline[0].input.resources[]? | {"res": .name, "tags": (.base.spec.forProvider.tags // {})}]',
         f],
        capture_output=True, text=True, timeout=30)
    if r.returncode != 0:
        continue
    for line in r.stdout.splitlines():
        line = line.strip()
        if not line or line == "null":
            continue
        try:
            arr = json.loads(line)
        except Exception:
            continue
        for entry in arr:
            for k, v in (entry.get("tags") or {}).items():
                if isinstance(v, str):
                    check(rel, f'resource {entry.get("res")} tag {k}', v)

for v in violations:
    print(v)
sys.exit(1 if violations else 0)
PYEOF
)"
status=$?

if [ "$status" -eq 0 ]; then
  pass "all committed tag-bound values use the AWS tag charset"
else
  while IFS= read -r line; do
    [ -n "$line" ] && fail "aws tag charset" "$line"
  done <<< "$out"
fi

summary
