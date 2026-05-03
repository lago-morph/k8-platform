---
name: crossplane-claim-verify
description: >-
  Use after applying a Crossplane Claim, XRD, or Composition (whether via
  kubectl, ArgoCD sync, or CI). Waits for Synced and Ready conditions on
  the claim and the underlying composite/managed resources, then verifies
  the intended cloud resource actually exists and is healthy. Diagnoses
  composition render errors, missing IRSA permissions, provider failures,
  and quota issues. Trigger when the user applies a claim, asks "did the
  claim provision?", asks to "verify the XRD", reports Crossplane errors,
  or syncs an ArgoCD app containing crossplane resources.
allowed-tools:
  - Bash
  - Read
  - Edit
  - Write
---

# Crossplane Claim Verify

Drives the loop after a Crossplane resource is applied: wait for
`Synced`/`Ready`, descend into the underlying managed resources, then
verify the actual cloud resource exists and matches the claim's intent.
Independent of `terraform-ci-watch` — use whichever fits the change.

## When to invoke

- A `Claim`, `XRD`, or `Composition` was applied (`kubectl apply`, ArgoCD
  sync, CI job, anything)
- The user asks "did the claim provision?", "is the XRD ready?", "did
  Crossplane work?"
- A `Pending` / `ReconcileError` / `Composition` failure is reported

## Prerequisites

Verify in one step:

- `kubectl` is configured against the management cluster
  (`kubectl get providers.pkg.crossplane.io` should return at least one
  provider, including `provider-aws` or similar)
- `aws` CLI is authenticated with credentials that can `Describe*` the
  resource types this claim provisions (read-only is enough)
- Read the project's `CLAUDE.md` and any per-XRD doc — the intended cloud
  resource shape determines the Phase 4 verification

## Phase 1 — Locate the claim

If the user named it: `kubectl get <claim-kind> -A` and pick by name.
Otherwise pick the most recently applied:

```sh
kubectl get <claim-kind> -A \
  --sort-by='.metadata.creationTimestamp' \
  -o jsonpath='{.items[-1].metadata.name},{.items[-1].metadata.namespace}'
```

Capture: `claim-name`, `namespace`, the `metadata.name` of the generated
composite (`spec.resourceRef.name` on the claim).

## Phase 2 — Wait for Synced + Ready

Poll every 10 seconds. Hard cap: 60 polls (10 minutes — compositions can
take longer than CI runs because they wait on real cloud APIs).

```sh
kubectl get <claim-kind>/<name> -n <ns> \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} reason={.reason}{"\n"}{end}'
```

Both `Synced=True` AND `Ready=True` required. See
`reference/readiness-conditions.md` for what each condition means and
common reasons.

## Phase 3 — Descend into managed resources

Once the claim is `Synced`, the composite (XR) lists its composed
resources. Walk them:

```sh
kubectl get <xr-kind>/<xr-name> \
  -o jsonpath='{range .spec.resourceRefs[*]}{.kind}/{.name}{"\n"}{end}'
```

For each managed resource, confirm `Synced=True` and `Ready=True` (same
condition shape as the claim). If any is stuck, that's where the failure
lives — `kubectl describe` it for events and reasons.

## Phase 4 — Verify the actual cloud resource

`Ready=True` means Crossplane *believes* the resource is healthy; it does
not guarantee the cloud-side state matches the claim's intent. Always do
an out-of-band check.

See `reference/cloud-verification.md` for per-XRD-kind recipes (this file
is a living catalog — add a recipe whenever a new XRD lands).

Examples:
- `PlatformCluster` → `aws eks describe-cluster --name <name>` returns
  `status=ACTIVE` and node group has the requested size
- `PlatformSecret` → `kubectl get secret <synced-name> -o jsonpath='{.data}'`
  matches the AWS Secrets Manager source value (base64-decoded)

## Phase 5 — On success

Report:
- Claim name + namespace
- XR name
- Each managed resource and its `Ready` reason
- The cloud-side proof (one-line per resource)

Stop. Do not delete or modify the claim.

## Phase 6 — On failure

1. **Classify** — see `reference/failure-taxonomy.md`. Match the failing
   resource's `status.conditions[].reason` and the `kubectl describe`
   events.
2. **Apply the fix** — only edit the file the taxonomy entry points at
   (often the XRD, the Composition, or an IRSA role in
   `terraform/management/irsa.tf`).
3. **Re-apply**:
   - For an XRD/Composition change: `kubectl apply -f <file>`
   - For an IRSA change: re-run the management Terraform (this is a
     `terraform-ci-watch` task — hand off if appropriate)
4. Increment attempt counter. Return to Phase 2.

If the taxonomy entry is "no — escalate" (e.g., quota, provider bug),
go straight to Phase 7.

## Phase 7 — Three-strike escalation

After 3 consecutive failed fix attempts, STOP and use
`reference/escalation-template.md`. Do not re-apply a 4th time.

## Companion skill

Composition or XRD changes that need to flow through CI (e.g., merged via
PR rather than `kubectl apply`-ed directly) trigger `terraform-ci-watch`
for the CI side AND this skill for the cluster-side outcome. Both run in
sequence: CI green → claim verified.
