#!/usr/bin/env bash
# Every namespaced manifest synced by the crossplane-resources Application
# must target a namespace that exists at bootstrap time.
#
# The bug class (clean build #4, 2026-07-05): crossplane/rbac/02-* put a
# Role/RoleBinding in namespace `platform`, which is created by the
# platform-cluster-claim Application — a MANUAL deliberate-sync gate that
# fires ~15+ minutes after bootstrap. crossplane-resources' automated sync
# failed ("namespaces \"platform\" not found"), exhausted its 5 retries,
# and sat Failed/OutOfSync until an unrelated commit would retrigger it.
# Builds #1–#3 were masked by mid-build merges to main; build #4 was the
# first build without one and hit it: the ADR-0010 registration-Secret
# producer had no RBAC, so the spoke never registered.
#
# File set mirrors argocd/apps/crossplane-resources.yaml exactly:
#   include: {xrds/*.yaml,compositions/*.yaml,rbac/*.yaml,providerconfig/*.yaml}
#   exclude: **/render-fixtures/**
# (cross-checked below so a future include-glob change fails this test
# loudly instead of silently diverging).
#
# Bootstrap-guaranteed namespaces for this app's sync:
#   - kube-system/default: cluster built-ins.
#   - crossplane-system, argocd, kyverno, external-secrets: created by the
#     management terraform helm releases BEFORE the ArgoCD bootstrap app
#     exists.
#   - any namespace created by a committed Namespace manifest in the same
#     file set (ArgoCD applies Namespaces before namespaced kinds).
# Anything else must ship with the Application that creates its namespace
# (e.g. clusters/platform/ for ns `platform`).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-helpers.sh"
require_tool yq

ROOT="$HERE/../.."
APP="$ROOT/argocd/apps/crossplane-resources.yaml"

# Guard: the include/exclude this test mirrors must still be what the app
# declares. If the app's file-selection changes, update BOTH together.
want_include='{xrds/*.yaml,compositions/*.yaml,rbac/*.yaml,providerconfig/*.yaml}'
got_include="$(yq -r '.spec.source.directory.include' "$APP")"
if [ "$got_include" = "$want_include" ]; then
  pass "app include glob matches the set this test scans"
else
  fail "app include glob drifted" "app: '$got_include' — update this test's file set to match"
fi

out="$(python3 - "$ROOT" <<'PYEOF'
import os, sys, glob, subprocess, json

root = sys.argv[1]
allowed = {"kube-system", "default", "crossplane-system", "argocd",
           "kyverno", "external-secrets"}
patterns = ["xrds/*.yaml", "compositions/*.yaml", "rbac/*.yaml",
            "providerconfig/*.yaml"]

files = []
for p in patterns:
    files.extend(glob.glob(os.path.join(root, "crossplane", p)))
files = sorted(f for f in set(files) if "/render-fixtures/" not in f)

violations, docs = [], []
for f in files:
    r = subprocess.run(
        ["yq", "eval-all", "-o=json", "-I0",
         '{"kind": .kind, "name": .metadata.name, "ns": (.metadata.namespace // "")}',
         f],
        capture_output=True, text=True, timeout=30)
    if r.returncode != 0:
        violations.append(f"PARSE-ERROR {os.path.relpath(f, root)}: {r.stderr.strip()[:120]}")
        continue
    for line in r.stdout.splitlines():
        line = line.strip()
        if not line or line == "null":
            continue
        d = json.loads(line)
        if d.get("kind"):
            docs.append((os.path.relpath(f, root), d["kind"], d.get("name"), d.get("ns") or ""))

self_created = {name for (_, kind, name, _) in docs if kind == "Namespace"}

for rel, kind, name, ns in docs:
    if not ns or ns in allowed or ns in self_created:
        continue
    violations.append(
        f"BOOTSTRAP-UNSAFE {rel}: {kind}/{name} targets namespace '{ns}' "
        f"which nothing available at bootstrap creates")

for v in violations:
    print(v)
sys.exit(1 if violations else 0)
PYEOF
)"
status=$?

if [ "$status" -eq 0 ]; then
  pass "crossplane-resources manifests target only bootstrap-guaranteed namespaces"
else
  while IFS= read -r line; do
    [ -n "$line" ] && fail "bootstrap-safe namespaces" "$line"
  done <<< "$out"
fi

summary
