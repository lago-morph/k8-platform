#!/usr/bin/env python3
"""IRSA trust-policy vs ServiceAccount fleet-sweep validator.

SPEC-S3. Read-only diagnostic. Decodes every IRSA role's trust policy,
extracts the expected `sub` claim(s), then checks whether the cluster
has matching ServiceAccount(s) with the correct
`eks.amazonaws.com/role-arn` annotation, and whether running pods carry
that SA. Emits MATCH/MISMATCH/WARN/ERROR per role.

Modes:
    --all                Sweep every IRSA role bound to the cluster's OIDC.
    --role <arn|name>    Process a single role (no discovery).
    --ci                 Exit 1 if any MISMATCH found (WARN/ERROR are info).

Fixture injection (offline unit tests):
    IRSA_VALIDATOR_MOCK_DIR=<path>  — read fixtures from <path>/<role>/...
                                       instead of calling AWS/kubectl.

Author: SPEC-S3 (brainstorm A1-018). Bug 5 (PR #66/#67/#68) defender.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

# -- constants ------------------------------------------------------------

ALLOWED_REGIONS = {"us-east-1", "us-west-2"}
MAX_SUBJECTS_PRINTED = 10
SUB_RE = re.compile(r"^system:serviceaccount:([^:]+):([^:]+)$")
ROLE_ARN_RE = re.compile(r"^arn:aws:iam::(\d{12}):role/(.+)$")

EXIT_OK = 0
EXIT_FAIL = 1


# -- mock + AWS/kubectl access --------------------------------------------


class MockBackend:
    """Reads canned JSON responses from a fixture directory.

    Layout:
        <root>/discovery.json
            { "account": "...", "region": "...", "cluster": "...",
              "oidc_issuer": "...", "roles": ["role-a", "role-b", ...] }
        <root>/<role-name>/trust.json
            { "AssumeRolePolicyDocument": {...}, "Arn": "arn:...",
              "_error": "optional: simulate iam:GetRole failure" }
        <root>/<role-name>/sa-<ns>-<sa>.json
            ServiceAccount JSON OR { "_missing": true }
        <root>/<role-name>/pods-<ns>.json
            List of {"name": ..., "serviceAccountName": ...,
                     "component": "..."} or {"_missing": true}
        <root>/<role-name>/sa-list-<ns>.json (optional inverse check)
            List of {"name": ..., "role_arn": "..."} entries.
    """

    def __init__(self, root: Path) -> None:
        self.root = root
        disc_path = root / "discovery.json"
        if not disc_path.exists():
            raise SystemExit(
                f"PREFLIGHT_FAILED: mock dir missing discovery.json: {root}"
            )
        with disc_path.open() as fh:
            self.discovery = json.load(fh)

    def preflight(self) -> dict[str, str]:
        return {
            "account": self.discovery["account"],
            "region": self.discovery["region"],
            "cluster": self.discovery["cluster"],
            "oidc_issuer": self.discovery["oidc_issuer"],
        }

    def list_roles(self) -> list[str]:
        return list(self.discovery.get("roles", []))

    def get_role(self, role_name: str) -> dict[str, Any]:
        path = self.root / role_name / "trust.json"
        if not path.exists():
            raise RuntimeError(f"mock trust.json missing for role {role_name}")
        with path.open() as fh:
            data = json.load(fh)
        if "_error" in data:
            raise RuntimeError(data["_error"])
        return data

    def get_sa(self, role_name: str, ns: str, sa: str) -> dict[str, Any] | None:
        path = self.root / role_name / f"sa-{ns}-{sa}.json"
        if not path.exists():
            return None
        with path.open() as fh:
            data = json.load(fh)
        if data.get("_missing"):
            return None
        if data.get("_error"):
            raise RuntimeError(data["_error"])
        return data

    def list_pods(self, role_name: str, ns: str) -> list[dict[str, Any]] | None:
        path = self.root / role_name / f"pods-{ns}.json"
        if not path.exists():
            return None
        with path.open() as fh:
            data = json.load(fh)
        if isinstance(data, dict) and data.get("_missing"):
            return None
        if isinstance(data, dict) and data.get("_error"):
            raise RuntimeError(data["_error"])
        return data

    def list_sas_in_ns(self, role_name: str, ns: str) -> list[dict[str, Any]] | None:
        path = self.root / role_name / f"sa-list-{ns}.json"
        if not path.exists():
            return None
        with path.open() as fh:
            return json.load(fh)


class LiveBackend:
    """Real backend: boto3 for IAM/EKS/STS, subprocess for kubectl."""

    def __init__(self, cluster_override: str | None = None) -> None:
        try:
            import boto3  # noqa: WPS433
        except ImportError as exc:
            raise SystemExit(
                "PREFLIGHT_FAILED: boto3 required for live mode "
                "(pip install boto3) — or set IRSA_VALIDATOR_MOCK_DIR"
            ) from exc
        self._boto3 = boto3
        self._iam = boto3.client("iam")
        self._sts = boto3.client("sts")
        self._eks = boto3.client("eks")
        self._cluster_override = cluster_override
        self._discovery: dict[str, str] | None = None

    def preflight(self) -> dict[str, str]:
        if self._discovery is not None:
            return self._discovery
        ident = self._sts.get_caller_identity()
        region = os.environ.get("AWS_DEFAULT_REGION") or os.environ.get("AWS_REGION")
        if not region:
            region = self._boto3.session.Session().region_name or ""
        if region not in ALLOWED_REGIONS:
            print(f"REGION_NOT_ALLOWED: {region}", file=sys.stderr)
            raise SystemExit(EXIT_FAIL)
        cluster = self._cluster_override or self._pick_cluster()
        desc = self._eks.describe_cluster(name=cluster)["cluster"]
        issuer = desc["identity"]["oidc"]["issuer"]
        self._discovery = {
            "account": ident["Account"],
            "region": region,
            "cluster": cluster,
            "oidc_issuer": issuer,
        }
        return self._discovery

    def _pick_cluster(self) -> str:
        clusters = self._eks.list_clusters().get("clusters", [])
        if len(clusters) == 0:
            raise SystemExit("PREFLIGHT_FAILED: no EKS clusters in region")
        if len(clusters) > 1:
            raise SystemExit(
                "PREFLIGHT_FAILED: multiple clusters; pass --cluster <name>"
            )
        return clusters[0]

    def list_roles(self) -> list[str]:
        info = self.preflight()
        # OIDC ARN: arn:aws:iam::<acct>:oidc-provider/<issuer-without-https://>
        issuer_host = info["oidc_issuer"].replace("https://", "")
        wanted_arn = f"arn:aws:iam::{info['account']}:oidc-provider/{issuer_host}"
        out: list[str] = []
        paginator = self._iam.get_paginator("list_roles")
        for page in paginator.paginate():
            for role in page.get("Roles", []):
                trust = role.get("AssumeRolePolicyDocument", {})
                for stmt in _statements(trust):
                    fed = stmt.get("Principal", {}).get("Federated")
                    if (isinstance(fed, str) and fed == wanted_arn) or (
                        isinstance(fed, list) and wanted_arn in fed
                    ):
                        if stmt.get("Action") in (
                            "sts:AssumeRoleWithWebIdentity",
                            ["sts:AssumeRoleWithWebIdentity"],
                        ):
                            out.append(role["RoleName"])
                            break
        return out

    def get_role(self, role_name: str) -> dict[str, Any]:
        return self._iam.get_role(RoleName=role_name)["Role"]

    def get_sa(self, role_name: str, ns: str, sa: str) -> dict[str, Any] | None:
        result = subprocess.run(
            ["kubectl", "get", "sa", sa, "-n", ns, "-o", "json"],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            stderr_l = result.stderr.lower()
            if "notfound" in stderr_l or "not found" in stderr_l:
                return None
            raise RuntimeError(f"kubectl: {result.stderr.strip()}")
        return json.loads(result.stdout)

    def list_pods(self, role_name: str, ns: str) -> list[dict[str, Any]] | None:
        result = subprocess.run(
            ["kubectl", "get", "pods", "-n", ns, "-o", "json"],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            raise RuntimeError(f"kubectl: {result.stderr.strip()}")
        items = json.loads(result.stdout).get("items", [])
        out: list[dict[str, Any]] = []
        for pod in items:
            labels = pod.get("metadata", {}).get("labels", {}) or {}
            comp = (
                labels.get("pkg.crossplane.io/provider")
                or labels.get("app.kubernetes.io/name")
                or ""
            )
            out.append(
                {
                    "name": pod.get("metadata", {}).get("name"),
                    "serviceAccountName": pod.get("spec", {}).get(
                        "serviceAccountName"
                    ),
                    "component": comp,
                }
            )
        return out

    def list_sas_in_ns(self, role_name: str, ns: str) -> list[dict[str, Any]] | None:
        result = subprocess.run(
            ["kubectl", "get", "sa", "-n", ns, "-o", "json"],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            raise RuntimeError(f"kubectl: {result.stderr.strip()}")
        items = json.loads(result.stdout).get("items", [])
        out: list[dict[str, Any]] = []
        for sa in items:
            annotations = sa.get("metadata", {}).get("annotations", {}) or {}
            arn = annotations.get("eks.amazonaws.com/role-arn")
            if arn:
                out.append({"name": sa["metadata"]["name"], "role_arn": arn})
        return out


# -- analysis -------------------------------------------------------------


def _statements(policy: dict[str, Any]) -> list[dict[str, Any]]:
    stmts = policy.get("Statement", [])
    if isinstance(stmts, dict):
        return [stmts]
    if isinstance(stmts, list):
        return stmts
    return []


def extract_subjects(trust: dict[str, Any], oidc_issuer: str) -> list[str]:
    """Return list of expected `sub` values from every StringEquals condition.

    `oidc_issuer` is the full URL; the condition key uses the hostname.
    """
    host = oidc_issuer.replace("https://", "")
    sub_key = f"{host}:sub"
    subjects: list[str] = []
    for stmt in _statements(trust):
        cond = stmt.get("Condition", {})
        for op_name, op_body in cond.items():
            if op_name not in ("StringEquals", "ForAnyValue:StringEquals"):
                continue
            value = op_body.get(sub_key)
            if value is None:
                # Also tolerate matching by suffix (any host) when the fixture
                # used a different OIDC URL than the one declared at discovery.
                for k, v in op_body.items():
                    if k.endswith(":sub"):
                        value = v
                        break
            if value is None:
                continue
            if isinstance(value, str):
                subjects.append(value)
            elif isinstance(value, list):
                subjects.extend(str(v) for v in value)
    return subjects


def parse_subject(sub: str) -> tuple[str, str] | None:
    m = SUB_RE.match(sub)
    if not m:
        return None
    return m.group(1), m.group(2)


def role_arn_for(role_name: str, role_obj: dict[str, Any], account: str) -> str:
    arn = role_obj.get("Arn") or role_obj.get("RoleArn")
    if arn:
        return arn
    return f"arn:aws:iam::{account}:role/{role_name}"


def role_basename(arn_or_name: str) -> str:
    m = ROLE_ARN_RE.match(arn_or_name)
    if m:
        return m.group(2)
    return arn_or_name


# -- per-role processing --------------------------------------------------


def analyse_role(
    backend: Any,
    role_name: str,
    discovery: dict[str, str],
    out: list[str],
) -> dict[str, int]:
    """Append the formatted block(s) for one role; return {'match','mismatch','warn','error'} counts."""
    counts = {"match": 0, "mismatch": 0, "warn": 0, "error": 0}
    try:
        role_obj = backend.get_role(role_name)
    except Exception as exc:  # noqa: BLE001 — fail-soft per spec §5.3
        out.append(f"ERROR    {role_name}")
        out.append(f"  iam:GetRole failed: {exc}")
        counts["error"] += 1
        return counts

    trust = role_obj.get("AssumeRolePolicyDocument", {})
    role_arn = role_arn_for(role_name, role_obj, discovery["account"])
    subjects = extract_subjects(trust, discovery["oidc_issuer"])

    if not subjects:
        out.append(f"WARN     {role_name}")
        out.append("  trust-sub:  (none extracted — non-IRSA trust shape?)")
        counts["warn"] += 1
        return counts

    cap = MAX_SUBJECTS_PRINTED
    extra = max(0, len(subjects) - cap)
    for sub in subjects[:cap]:
        parsed = parse_subject(sub)
        if parsed is None:
            out.append(f"WARN     {role_name}")
            out.append(f"  WARN: unparseable sub claim: {sub}")
            counts["warn"] += 1
            continue
        ns, sa_expected = parsed
        _emit_subject_block(
            backend, role_name, role_arn, ns, sa_expected, out, counts
        )
    if extra:
        out.append(f"  (+{extra} more subjects)")
    return counts


def _emit_subject_block(
    backend: Any,
    role_name: str,
    role_arn: str,
    ns: str,
    sa_expected: str,
    out: list[str],
    counts: dict[str, int],
) -> None:
    sub_line = f"system:serviceaccount:{ns}:{sa_expected}"
    # SA presence
    sa_obj: dict[str, Any] | None
    sa_err: str | None = None
    try:
        sa_obj = backend.get_sa(role_name, ns, sa_expected)
    except Exception as exc:  # noqa: BLE001
        sa_obj = None
        sa_err = str(exc)

    sa_exists = sa_obj is not None
    annotation_ok = False
    if sa_obj is not None:
        annotations = sa_obj.get("metadata", {}).get("annotations", {}) or {}
        ann_arn = annotations.get("eks.amazonaws.com/role-arn")
        annotation_ok = ann_arn == role_arn

    # Pod liveness
    pods_err: str | None = None
    try:
        pods = backend.list_pods(role_name, ns)
    except Exception as exc:  # noqa: BLE001
        pods = None
        pods_err = str(exc)

    pod_sa: str | None = None
    pod_sa_other: str | None = None
    pod_present = False
    if pods is not None:
        comp_match = _component_hint(role_name)
        for pod in pods:
            comp = (pod.get("component") or "").lower()
            if comp_match and comp_match in comp:
                pod_present = True
                psa = pod.get("serviceAccountName")
                if psa == sa_expected:
                    pod_sa = psa
                else:
                    pod_sa_other = psa
                    break
        if pod_sa is None and pod_sa_other is None and not pod_present:
            # Fallback: any pod in ns referencing the SA?
            for pod in pods:
                if pod.get("serviceAccountName") == sa_expected:
                    pod_sa = sa_expected
                    pod_present = True
                    break

    # Decide status
    status = "MATCH"
    if not sa_exists:
        status = "MISMATCH"
    elif not annotation_ok:
        status = "MISMATCH"
    elif pod_sa_other is not None:
        status = "MISMATCH"
    elif pods is None or not pod_present:
        status = "WARN"

    out.append(f"{status:<8} {role_name}")
    out.append(f"  trust-sub:  {sub_line}")
    sa_str = "yes" if sa_exists else "no"
    extras = []
    if sa_err:
        extras.append(f"sa-error: {sa_err}")
    if sa_exists:
        ann_str = "yes" if annotation_ok else "no"
        out.append(f"  sa-exists:  {sa_str}   annotation-ok: {ann_str}")
    else:
        out.append(f"  sa-exists:  {sa_str}")

    if pods_err:
        out.append(f"  KUBECTL_UNAVAIL: {pods_err}")
    elif pod_sa_other is not None:
        out.append(
            f"  pod-sa:     {pod_sa_other}   "
            f"← pod is running under wrong SA"
        )
    elif pod_sa is not None:
        out.append(f"  pod-sa:     {pod_sa}")
    elif pods is None:
        out.append("  pod-sa:     (kubectl unavailable)")
    elif not pod_present:
        out.append(
            "  pod-sa:     (no matching pods found — not necessarily an error)"
        )

    # Inverse / orphan check (optional)
    try:
        ns_sas = backend.list_sas_in_ns(role_name, ns)
    except Exception:
        ns_sas = None
    if ns_sas:
        orphans = [
            entry["name"]
            for entry in ns_sas
            if entry.get("role_arn") == role_arn and entry["name"] != sa_expected
        ]
        if orphans:
            out.append(
                f"  orphan-annot: {','.join(orphans)} "
                f"(SA annotated for this role but not in trust sub)"
            )

    for extra_line in extras:
        out.append(f"  {extra_line}")

    counts[status.lower()] += 1


def _component_hint(role_name: str) -> str:
    # Strip irsa_/IRSA prefix conventions, lower-case for label fuzzy match.
    name = role_name.lower()
    for prefix in ("irsa-", "irsa_", "eks-", "k8s-"):
        if name.startswith(prefix):
            name = name[len(prefix) :]
    return name


# -- single-role mode helper ---------------------------------------------


def resolve_single_role_name(arn_or_name: str) -> str:
    m = ROLE_ARN_RE.match(arn_or_name)
    if m:
        return m.group(2)
    return arn_or_name


# -- top-level driver -----------------------------------------------------


def build_backend(args: argparse.Namespace) -> Any:
    mock_dir = os.environ.get("IRSA_VALIDATOR_MOCK_DIR")
    if mock_dir:
        return MockBackend(Path(mock_dir))
    # Pre-flight: region guard happens inside LiveBackend.preflight().
    return LiveBackend(cluster_override=args.cluster)


def run(args: argparse.Namespace) -> int:
    backend = build_backend(args)
    try:
        discovery = backend.preflight()
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001
        print(f"PREFLIGHT_FAILED: {exc}", file=sys.stderr)
        return EXIT_FAIL

    if args.role:
        role_names = [resolve_single_role_name(args.role)]
    else:
        role_names = backend.list_roles()

    out: list[str] = []
    out.append("=== IRSA TRUST VALIDATOR ===")
    out.append(
        f"account: {discovery['account']}   "
        f"region: {discovery['region']}   "
        f"cluster: {discovery['cluster']}"
    )
    out.append(f"OIDC issuer: {discovery['oidc_issuer']}")
    out.append(f"roles discovered: {len(role_names)}")
    out.append("")

    totals = {"match": 0, "mismatch": 0, "warn": 0, "error": 0}
    for role_name in role_names:
        counts = analyse_role(backend, role_name, discovery, out)
        for k, v in counts.items():
            totals[k] += v
        out.append("")

    out.append(
        f"=== SUMMARY: {totals['match']} MATCH  "
        f"{totals['mismatch']} MISMATCH  "
        f"{totals['warn']} WARN  "
        f"{totals['error']} ERROR ==="
    )

    print("\n".join(out))

    if args.ci and totals["mismatch"] > 0:
        return EXIT_FAIL
    return EXIT_OK


def make_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="irsa_trust_validator.py",
        description=(
            "IRSA trust-policy vs ServiceAccount fleet-sweep validator. "
            "Read-only diagnostic. SPEC-S3."
        ),
    )
    mode = p.add_mutually_exclusive_group(required=True)
    mode.add_argument(
        "--all",
        action="store_true",
        help="Sweep every IRSA role bound to the cluster's OIDC.",
    )
    mode.add_argument(
        "--role",
        metavar="ARN_OR_NAME",
        help="Process a single role by ARN or name (no discovery).",
    )
    p.add_argument(
        "--cluster",
        metavar="NAME",
        help="EKS cluster name (required if multiple clusters in region).",
    )
    p.add_argument(
        "--ci",
        action="store_true",
        help="Exit 1 if any MISMATCH found (WARN/ERROR are informational).",
    )
    p.add_argument(
        "--debug",
        action="store_true",
        help="Verbose backend tracing (currently no-op placeholder).",
    )
    return p


def main(argv: list[str] | None = None) -> int:
    parser = make_parser()
    args = parser.parse_args(argv)
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
