#!/usr/bin/env bash
# fetch-crds-for-kubeconform.sh — populate kubeconform-schemas/ from CRDs.
#
# Two modes, picked automatically:
#
#   1. LIVE CLUSTER MODE — if `kubectl` works and KUBECONFIG points at a
#      reachable cluster, fetch every installed CRD via
#      `kubectl get crds -o json` and convert its openAPIV3Schema to a
#      JSON file under `kubeconform-schemas/<group>/<kind>_<version>.json`
#      (kubeconform's standard local layout, per SPEC-S6 §5.1).
#
#   2. PUBLISHED-CRD MODE — if no cluster is reachable (CI runner, fresh
#      sandbox, account rotation), fall back to fetching the same CRDs
#      from upstream GitHub releases. Versions are pinned (see CRD_URLS
#      below). SPEC-S6 §13 calls this out as the bootstrap path.
#
# The function-patch-and-transform input schema (pt.fn.crossplane.io,
# SPEC-S6 §5.3) is fetched from upstream regardless of mode — it ships
# in the function's OCI package and is never installed in the cluster
# as a CRD.
#
# Two transformations applied to every emitted schema file:
#
#   - `$schema: http://json-schema.org/draft-07/schema#` is injected if
#     missing. Without this kubeconform treats the file as not-a-schema
#     and marks the resource statusSkipped even though it loads.
#
#   - `additionalProperties: false` is set on every `type: object` node
#     that carries explicit `properties` and does not opt-out via
#     `x-kubernetes-preserve-unknown-fields: true`. This is the
#     load-bearing transformation that lets kubeconform reject unknown
#     fields like `forceOverwriteReplica` (the PR #74 Bug 1 typo).
#     Upstream CRD YAMLs ship without it; the API server adds it at
#     install time, which is why the bug was caught only at admission.
#
# Output: writes one JSON file per (group, kind, apiVersion) tuple to
# $STORE_DIR (default kubeconform-schemas/). Commit the diff in the
# same PR as the manifest that needs the new schema.
#
# Re-run after:
#   - bumping Crossplane / Kyverno / ESO / ArgoCD / provider-aws versions
#     in versions.env (or any helm chart pin)
#   - adding a new CRD group used by repo manifests
#   - upgrading the function-patch-and-transform pin

set -euo pipefail

STORE_DIR="${STORE_DIR:-kubeconform-schemas}"
mkdir -p "$STORE_DIR"

cd "$(dirname "$0")/.."  # repo root

# ArgoCD CRD pins come from the single source (versions.env,
# ARGOCD_APP_VERSION — the app version shipped by the deployed chart).
# tests/unit/test_version_pin_consistency.sh gates this wiring.
# shellcheck disable=SC1091
. ./versions.env

# Shared Python converter — both the live-cluster path and the
# published-CRD path source-include this as a module so the two
# transformations (above) live in exactly one place.
CONVERTER_PY=$(cat <<'PY'
import json, pathlib

DRAFT07 = "http://json-schema.org/draft-07/schema#"

def harden_schema(schema):
    """Inject $schema, allow K8s envelope keys, recursively forbid extras."""
    if not isinstance(schema, dict):
        return schema
    schema.setdefault("$schema", DRAFT07)
    # CRD openAPIV3Schema typically declares only spec/status. Allow the
    # standard K8s envelope keys at the root so apiVersion/kind/metadata
    # don't trip the recursive additionalProperties=false transformation.
    schema.setdefault("type", "object")
    props = schema.setdefault("properties", {})
    props.setdefault("apiVersion", {"type": "string"})
    props.setdefault("kind", {"type": "string"})
    props.setdefault("metadata", {"type": "object"})
    def _strict(node):
        if isinstance(node, dict):
            if (
                node.get("type") == "object"
                and "properties" in node
                and "additionalProperties" not in node
                and not node.get("x-kubernetes-preserve-unknown-fields")
            ):
                node["additionalProperties"] = False
            for v in node.values():
                _strict(v)
        elif isinstance(node, list):
            for v in node:
                _strict(v)
    _strict(schema)
    return schema

def write_schema(store_dir, group, kind, version, schema):
    dest = pathlib.Path(store_dir) / group / f"{kind.lower()}_{version}.json"
    dest.parent.mkdir(parents=True, exist_ok=True)
    schema = harden_schema(schema)
    dest.write_text(json.dumps(schema, indent=2) + "\n")
    return dest
PY
)

# --- 1. live cluster mode (if kubectl reachable) ---------------------------
if command -v kubectl >/dev/null 2>&1 && kubectl version --request-timeout=3s >/dev/null 2>&1; then
  echo "==> live cluster mode (kubectl reachable)"
  kubectl get crds -o json | STORE_DIR="$STORE_DIR" CONVERTER_PY="$CONVERTER_PY" python3 - <<'PY'
import json, sys, os
exec(os.environ["CONVERTER_PY"])
store = os.environ["STORE_DIR"]
count = 0
for item in json.load(sys.stdin).get("items", []):
    group = item["spec"]["group"]
    kind = item["spec"]["names"]["kind"]
    for ver in item["spec"]["versions"]:
        schema = ver.get("schema", {}).get("openAPIV3Schema")
        if not schema:
            continue
        dest = write_schema(store, group, kind, ver["name"], schema)
        print(f"  wrote {dest}")
        count += 1
print(f"==> {count} schemas written from live cluster")
PY
else
  echo "==> no live cluster reachable; using PUBLISHED-CRD MODE"
fi

# --- 2. published CRD bootstrap (always run; safe to overlay live mode) ----
#
# Crossplane v2 migration (SEG-4): the AWS provider CRDs are pinned to
# provider-upjet-aws v2.5.0 and use the new namespaced `.aws.m.upbound.io`
# group. The legacy cluster-scoped `.aws.upbound.io_*.yaml` URLs are
# DELIBERATELY OMITTED — v2.5.0 ships both groups for back-compat but
# the repo has hard-cutover to namespaced v2 MRs. Re-adding legacy URLs
# would produce a dual-schema store.
CRD_URLS=(
  "https://raw.githubusercontent.com/crossplane/crossplane/v2.3.0/cluster/crds/apiextensions.crossplane.io_compositions.yaml"
  "https://raw.githubusercontent.com/crossplane/crossplane/v2.3.0/cluster/crds/apiextensions.crossplane.io_compositeresourcedefinitions.yaml"
  "https://raw.githubusercontent.com/external-secrets/external-secrets/v0.10.4/deploy/crds/bundle.yaml"
  # ArgoCD CRDs pinned to the DEPLOYED version via versions.env
  # ARGOCD_APP_VERSION (the app version the pinned chart ships — see the
  # paired-pin note there). Previously hardcoded v2.13.1 — a skew vs the
  # deployed v2.10 controller that ADR-0010's review flagged; the schemas
  # must validate what the deployed ArgoCD admits.
  # applicationset-crd.yaml added by ADR-0010 (the spoke apps are now
  # ApplicationSets; without this schema kubeconform silently SKIPS them
  # via --ignore-missing-schemas and validates nothing).
  "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_APP_VERSION}/manifests/crds/application-crd.yaml"
  "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_APP_VERSION}/manifests/crds/appproject-crd.yaml"
  "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_APP_VERSION}/manifests/crds/applicationset-crd.yaml"
  "https://raw.githubusercontent.com/crossplane-contrib/provider-upjet-aws/v2.5.0/package/crds/secretsmanager.aws.m.upbound.io_secrets.yaml"
  "https://raw.githubusercontent.com/crossplane-contrib/provider-upjet-aws/v2.5.0/package/crds/ec2.aws.m.upbound.io_vpcs.yaml"
  "https://raw.githubusercontent.com/crossplane-contrib/provider-upjet-aws/v2.5.0/package/crds/ec2.aws.m.upbound.io_subnets.yaml"
  "https://raw.githubusercontent.com/crossplane-contrib/provider-upjet-aws/v2.5.0/package/crds/ec2.aws.m.upbound.io_internetgateways.yaml"
  "https://raw.githubusercontent.com/crossplane-contrib/provider-upjet-aws/v2.5.0/package/crds/ec2.aws.m.upbound.io_routes.yaml"
  "https://raw.githubusercontent.com/crossplane-contrib/provider-upjet-aws/v2.5.0/package/crds/eks.aws.m.upbound.io_clusters.yaml"
  "https://raw.githubusercontent.com/crossplane-contrib/provider-upjet-aws/v2.5.0/package/crds/eks.aws.m.upbound.io_nodegroups.yaml"
  "https://raw.githubusercontent.com/crossplane-contrib/provider-upjet-aws/v2.5.0/package/crds/iam.aws.m.upbound.io_roles.yaml"
  "https://raw.githubusercontent.com/crossplane-contrib/provider-upjet-aws/v2.5.0/package/crds/iam.aws.m.upbound.io_rolepolicyattachments.yaml"
  # auto-008 (XSpokeAccess) — the spoke hub-access Composition renders an
  # OpenIDConnectProvider (the spoke IRSA anchor), an INLINE RolePolicy for
  # external-dns (the crossplane IRSA has iam:PutRolePolicy not
  # iam:CreatePolicy, C4), and an EKS AccessEntry +
  # AccessPolicyAssociation mapping the argocd role to the spoke (C3).
  # Pinned to the same provider-upjet-aws v2.5.0 as the other AWS CRDs.
  "https://raw.githubusercontent.com/crossplane-contrib/provider-upjet-aws/v2.5.0/package/crds/iam.aws.m.upbound.io_openidconnectproviders.yaml"
  "https://raw.githubusercontent.com/crossplane-contrib/provider-upjet-aws/v2.5.0/package/crds/iam.aws.m.upbound.io_rolepolicies.yaml"
  "https://raw.githubusercontent.com/crossplane-contrib/provider-upjet-aws/v2.5.0/package/crds/eks.aws.m.upbound.io_accessentries.yaml"
  "https://raw.githubusercontent.com/crossplane-contrib/provider-upjet-aws/v2.5.0/package/crds/eks.aws.m.upbound.io_accesspolicyassociations.yaml"
  # Phase 5 — the per-cluster OIDC IdentityProviderConfig federating
  # kubectl auth to the Keycloak platform realm (REQ-AUTH-07).
  "https://raw.githubusercontent.com/crossplane-contrib/provider-upjet-aws/v2.5.0/package/crds/eks.aws.m.upbound.io_identityproviderconfigs.yaml"
  # Phase 3 — per-cluster ACM certificate provisioned inside the cluster
  # Composition (acm Certificate + route53 validation Record + acm
  # CertificateValidation). Pinned to the same provider-upjet-aws v2.5.0
  # as the EKS/IAM/secretsmanager CRDs above.
  "https://raw.githubusercontent.com/crossplane-contrib/provider-upjet-aws/v2.5.0/package/crds/acm.aws.m.upbound.io_certificates.yaml"
  "https://raw.githubusercontent.com/crossplane-contrib/provider-upjet-aws/v2.5.0/package/crds/acm.aws.m.upbound.io_certificatevalidations.yaml"
  "https://raw.githubusercontent.com/crossplane-contrib/provider-upjet-aws/v2.5.0/package/crds/route53.aws.m.upbound.io_records.yaml"
  # Phase 5 — XDatabase abstraction backed by an RDS Instance (the
  # xdatabase-rds Composition provisions a postgres rds.aws.m.upbound.io
  # Instance). Pinned to the same provider-upjet-aws v2.5.0 as the other
  # AWS CRDs above so the kubeconform store stays single-version.
  "https://raw.githubusercontent.com/crossplane-contrib/provider-upjet-aws/v2.5.0/package/crds/rds.aws.m.upbound.io_instances.yaml"
)

KYVERNO_BUNDLE_URL="https://github.com/kyverno/kyverno/raw/v1.13.0/config/install-latest-testing.yaml"
FUNCTION_PT_URL="https://raw.githubusercontent.com/crossplane-contrib/function-patch-and-transform/v0.10.6/package/input/pt.fn.crossplane.io_resources.yaml"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

convert_one() {
  local yaml_path="$1"
  STORE_DIR="$STORE_DIR" CONVERTER_PY="$CONVERTER_PY" python3 - "$yaml_path" <<'PY'
import yaml, sys, os
exec(os.environ["CONVERTER_PY"])
store = os.environ["STORE_DIR"]
count = 0
with open(sys.argv[1]) as fh:
    for doc in yaml.safe_load_all(fh):
        if not doc or doc.get("kind") != "CustomResourceDefinition":
            continue
        group = doc["spec"]["group"]
        kind = doc["spec"]["names"]["kind"]
        for ver in doc["spec"]["versions"]:
            schema = ver.get("schema", {}).get("openAPIV3Schema")
            if not schema:
                continue
            dest = write_schema(store, group, kind, ver["name"], schema)
            print(f"  wrote {dest}")
            count += 1
print(f"  ({count} schemas from {sys.argv[1]})")
PY
}

for url in "${CRD_URLS[@]}"; do
  out="$TMP/$(basename "$url")"
  echo "==> fetching $url"
  if curl -fsSL "$url" -o "$out"; then
    convert_one "$out"
  else
    echo "  WARN: failed to fetch $url" >&2
  fi
done

echo "==> fetching $KYVERNO_BUNDLE_URL"
kyv_out="$TMP/kyverno-install.yaml"
if curl -fsSL "$KYVERNO_BUNDLE_URL" -o "$kyv_out"; then
  convert_one "$kyv_out"
else
  echo "  WARN: failed to fetch kyverno install bundle" >&2
fi

echo "==> fetching $FUNCTION_PT_URL"
fpt_out="$TMP/function-pt.yaml"
if curl -fsSL "$FUNCTION_PT_URL" -o "$fpt_out"; then
  convert_one "$fpt_out"
else
  echo "  WARN: failed to fetch function-patch-and-transform schema" >&2
fi

# --- 3. extract schemas from this repo's own XRDs --------------------------
echo "==> extracting schemas from repo XRDs (platform.k8-platform.io)"
STORE_DIR="$STORE_DIR" CONVERTER_PY="$CONVERTER_PY" python3 - <<'PY'
import yaml, os, pathlib
exec(os.environ["CONVERTER_PY"])
store = os.environ["STORE_DIR"]
count = 0
for xrd_path in sorted(pathlib.Path("crossplane/xrds").glob("*.yaml")):
    for doc in yaml.safe_load_all(open(xrd_path)):
        if not doc or doc.get("kind") != "CompositeResourceDefinition":
            continue
        spec = doc["spec"]
        group = spec["group"]
        x_kind = spec["names"]["kind"]
        # Crossplane v2 XRDs (apiextensions.crossplane.io/v2) have no
        # claimNames — the XR is itself the user-facing object. Older
        # v1 XRDs carried both an XR kind and a claim kind; emitting
        # only x_kind is correct for v2 and merely loses an alias for
        # v1 (legacy v1 XRDs will be gone after SEG-1 wave 2).
        for ver in spec["versions"]:
            schema = ver.get("schema", {}).get("openAPIV3Schema")
            if not schema:
                continue
            if not x_kind:
                continue
            dest = write_schema(store, group, x_kind, ver["name"], schema)
            print(f"  wrote {dest}")
            count += 1
print(f"  ({count} schemas from repo XRDs)")
PY

echo ""
echo "==> done. Schema store at $STORE_DIR/"
find "$STORE_DIR" -type f -name '*.json' | wc -l | xargs -I{} echo "    {} schemas total"
