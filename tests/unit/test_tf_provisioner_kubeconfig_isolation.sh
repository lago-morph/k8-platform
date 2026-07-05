#!/usr/bin/env bash
# Every terraform local-exec provisioner must use its OWN kubeconfig path.
#
# The bug class (clean build #4, 2026-07-05, runs 28747505753 + 28749110239):
# six terraform_data provisioners in terraform/management/helm.tf all wrote
# and read the SAME /tmp/k8-platform-kubeconfig. Terraform runs provisioners
# with parallelism 10, and `aws eks update-kubeconfig` truncate-rewrites the
# file — so any concurrent pair races, and the loser's kubectl finds an
# empty config and falls back to localhost:8080 ("connection refused",
# "failed to download openapi"). The race is timing-dependent: three clean
# builds won it; build #4 lost it twice with two different victims (the
# rds-provider provisioner, then the argocd bootstrap apply).
#
# Contract enforced here, per resource block in terraform/**/*.tf:
#   1. No kubeconfig path literal is shared by two different resource
#      blocks (per-resource isolation — the durable fix).
#   2. Within one block, every kubeconfig literal is identical (the
#      update-kubeconfig writer and each KUBECONFIG= reader must agree,
#      else the block reads a file nothing wrote).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-helpers.sh"

ROOT="$HERE/../.."

out="$(python3 - "$ROOT" <<'PYEOF'
import re, sys, glob, os

root = sys.argv[1]
violations = []
shared = {}   # path literal -> set of "file:resource" users

for tf in glob.glob(os.path.join(root, "terraform", "**", "*.tf"), recursive=True):
    text = open(tf).read()
    rel = os.path.relpath(tf, root)
    # Split into resource blocks by header lines; the preamble (chunk 0)
    # is ignored for ownership but scanned for stray kubeconfig literals.
    parts = re.split(r'(?m)^(resource\s+"[^"]+"\s+"[^"]+")', text)
    it = iter(parts[1:])
    for header, body in zip(it, it):
        m = re.match(r'resource\s+"([^"]+)"\s+"([^"]+)"', header)
        res = f"{rel}:{m.group(1)}.{m.group(2)}"
        paths = set(re.findall(r'/tmp/[A-Za-z0-9._\-]*kubeconfig[A-Za-z0-9._\-]*', body))
        if not paths:
            continue
        if len(paths) > 1:
            violations.append(
                f"INTERNAL-MISMATCH {res} uses {len(paths)} distinct kubeconfig paths: {sorted(paths)}")
        for p in paths:
            shared.setdefault(p, set()).add(res)

for p, users in sorted(shared.items()):
    if len(users) > 1:
        violations.append(
            f"SHARED {p} used by {len(users)} resource blocks: {sorted(users)}")

for v in violations:
    print(v)
sys.exit(1 if violations else 0)
PYEOF
)"
status=$?

if [ "$status" -eq 0 ]; then
  pass "every provisioner kubeconfig path is block-unique and internally consistent"
else
  while IFS= read -r line; do
    [ -n "$line" ] && fail "kubeconfig isolation" "$line"
  done <<< "$out"
fi

summary
