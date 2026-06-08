# Spec: `crossplane-behavioral-oracle-check`

- **ID**: SKILL-SPEC-7a1f50b591
- **Source retrospective**: ../2026-06-08-199.md

## Intent

Author a read-only "after"-tier live check that proves a Crossplane abstraction
actually produced a real, healthy cloud resource — not that a manifest says so
(the ADR-0006 behavioral-oracle pattern). In auto-014 this exact pattern was
applied 13 times (one per pending kind) and is a repeatable, templatable
procedure: select the real resource by the provider's own stamp, evaluate health,
and obey the live-suite exit-code contract so the orchestrator can promote a
missing-but-declared kind to a FAIL. It earns a place in the library because every
new composed managed-resource kind needs one, and getting the selection/health/
exit-code details wrong silently produces a useless or false oracle.

## Trigger

Activate when: a new composed managed-resource kind is added to a Crossplane
Composition and `tests/coverage/registry.yaml` shows it `pending:P*`; the user
asks to "write the behavioral/live check for <kind>"; or a coverage-deriver test
WARNs that a kind has no real `defended_by`. Negative triggers: static manifest
lints (those are the push/PR floor, not a behavioral oracle); kinds whose
verification requires MUTATION (that is the instantiate tier, not after-tier).

## Inputs

- The kind (`<group>/<Kind>`) and its Composition (for the tags/stamps it sets).
- The reference check `tests/live/checks/after/rds-instance-live.sh` and the
  contract in `tests/live/lib/live-lib.sh`.
- Live AWS creds (to validate read-only) and, for non-AWS kinds, the kube relay
  helper `scripts/sandbox-kubeconfig.sh`.

## Outputs

- `tests/live/checks/after/<service>-<kind>-live.sh`, executable, shellcheck-clean.
- An updated `defended_by` entry in `tests/coverage/registry.yaml`.
- An observed live result (PASS+COVERS, or a correct SKIP with the reason).

## Workflow

1. Copy the structure/header/preamble of `rds-instance-live.sh` (set -uo pipefail,
   HERE/REPO_ROOT, source live-lib.sh, `KIND=...`, `REGION=...`).
2. Tooling/creds preconditions are SKIPs: `for bin in aws jq; do command -v ... || skip; done`, then `aws sts get-caller-identity || skip`.
3. Select the real resource by the provider stamp: prefer the tag
   `crossplane-kind=<kind>.<group>` (plus `PlatformAbstraction=<abstraction>`),
   never by name. For tag-less kinds (RolePolicy, RolePolicyAttachment,
   AccessPolicyAssociation, Route53 Record) select indirectly via a stamped parent.
4. Absent resource => `skip` (the orchestrator promotes to FAIL iff expect-full).
5. Evaluate the terminal health signal (e.g. EKS ACTIVE, ACM ISSUED, secret has an
   AWSCURRENT version). Unhealthy => `ng "..."; exit 1`. A value-less leftover =>
   SKIP, not FAIL. NEVER read secret material.
6. Healthy => `ok "..."; covers "$KIND"; exit "$LIVE_RC_PASS"`.
7. `chmod +x`; shellcheck clean; run it read-only against the live account and
   record the rc + COVERS line; flip the registry `defended_by` to the file path.

## Concrete examples

1. **acm Certificate** — `list-certificates` + `list-tags-for-certificate`, match
   `crossplane-kind=certificate.acm.aws.m.upbound.io`; health = `describe-certificate`
   `.Status == ISSUED`. Live result: rc=0, `COVERS acm.aws.m.upbound.io/Certificate`.
2. **route53 Record** (tag-less) — find the crossplane ACM cert, read its
   `DomainValidationOptions[].ResourceRecord`, then assert that exact CNAME exists
   with the expected value in the zone. Proves the Record MR wrote real DNS.

## Anti-patterns

- Selecting by resource name (auto-014: a Crossplane RDS instance is named
  `terraform-<rand>`; name-matching misses it and matches Terraform lookalikes).
- Hard-FAILing on a value-less/leftover resource (turns the whole suite RED).
- Reading secret material (`get-secret-value`) — existence/version staging only.
- Putting the kind in expect-full when the check can't run under the scoped CI role.

## Acceptance criteria

- Exits 0 + emits exactly one `COVERS <kind>` line when the resource is healthy.
- SKIPs (exit 2) cleanly on missing tooling/creds/permission OR an absent resource.
- `ng` + non-zero exit only on a genuinely unhealthy real resource.
- shellcheck-clean; read-only (no create/modify/delete; no secret decode).
- Validated live against a real account (records the observed rc).

## Files this skill creates / modifies

- `tests/live/checks/after/<service>-<kind>-live.sh` — the new behavioral oracle.
- `tests/coverage/registry.yaml` — flips the kind's `defended_by` to the new path.
