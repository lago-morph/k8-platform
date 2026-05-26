# Chainsaw harness

This directory contains the **Chainsaw test infrastructure** for Crossplane
XRDs and Compositions, per `ai/TESTING-PLAN.md` §"Layer 4 (planned)".

## What it does

For each push to `crossplane/**`, `tests/chainsaw/**`, or this workflow,
CI:

1. Creates a fresh `kind` cluster (pinned node image + digest).
2. Installs Crossplane v2 (pinned chart version) + Upbound
   `provider-family-aws` (pinned package version).
3. Runs every scenario under this directory via `chainsaw test`.
4. Tears the cluster down — and (best-effort) deletes any AWS Secrets
   Manager secrets the run created under the `k8-platform-chainsaw-*`
   prefix.

Scenarios run **serially** because they share the kind cluster; parallel
Composition apply has caused webhook flakes historically. Tight default
timeouts (30s apply, 60s assert) are set in `chainsaw-config.yaml`.

## What it does NOT do

- Doesn't replace the live-cluster integration tests in
  `tests/integration/` — those catch real-IRSA / real-Route53 / real-rate-
  limit issues a kind+kubectl setup can't see.
- Doesn't run on every push — only on paths that affect what it tests.
- Doesn't install ESO, ingress-nginx, ArgoCD, or anything else in
  Crossplane's runtime path. If a scenario needs them it must apply
  them in a setup step (and assert them Ready).

## Layout

```
tests/chainsaw/
├── README.md                  # this file
├── versions.env               # pinned versions for kind, crossplane, chainsaw, AWS provider
├── kind-config.yaml           # kind cluster config (1 node, pinned image)
├── chainsaw-config.yaml       # shared chainsaw config (timeouts, parallel=1)
├── run.sh                     # orchestrator: kind create → install → chainsaw → cleanup
└── <xrd-name>/
    └── NN-scenario-name/
        └── chainsaw-test.yaml # one scenario per dir
```

A leading `_` on a scenario dir (e.g. `_smoke/`) marks it as
infrastructure-only; useful for harness self-checks.

## Running locally

```sh
# requires: kind, kubectl, helm, chainsaw CLI, aws CLI
tests/chainsaw/run.sh

# single scenario
CHAINSAW_SCENARIOS=_smoke tests/chainsaw/run.sh
```

## Adding a new XRD

1. Add the XRD + Composition under `crossplane/{xrds,compositions}/`.
2. Create `tests/chainsaw/<xrd-name>/` and at minimum:
   - `00-claim-creates-resource/` — happy-path apply + assert
   - `01-claim-deletion-cleanup/` — delete + assert cleanup
3. Apply `tests/unit/test_chainsaw_kind_config.sh` style: add structural
   unit tests for the XRD / Composition under `tests/unit/`.
4. Run locally before pushing.

## Authoring a new scenario (SPEC-A4 catch-block requirement)

Every chainsaw scenario MUST inherit the canonical `catch:` block from
[`_lib/catch-block.yaml`](./_lib/catch-block.yaml). The block runs on
any step failure and emits the XR `describe`, every referenced MR's
`describe`, and recent reconcile events — inline in the chainsaw log
so a red CI run is self-diagnostic without re-running locally.

To add a scenario:

1. Copy the contents of `_lib/catch-block.yaml` into your new
   scenario's `Test.spec.catch:` list.
2. Edit only the first `describe.kind` to match your XR
   (`PlatformSecret`, `PlatformCluster`, etc.).
3. The unit test `tests/unit/test_chainsaw_catch_block.sh` enforces
   block presence + structural equality on every push.

The [`meta-catch-fires/`](./meta-catch-fires/) scenario is the
exemplar — its single step deliberately fails so the catch block
fires every CI run, proving the diagnostic plumbing still works.
`run.sh` inverts the exit-code expectation for any scenario whose
directory begins with `meta-`.

## Why pinned versions matter

kind, the kindest/node image, Crossplane chart, and the AWS provider
package are all pinned in `versions.env`. Drift between this file and
the management module's `terraform/management/variables.tf` versions
means a Composition can test green here and break in management, or
vice versa. `tests/unit/test_chainsaw_kind_config.sh` enforces the
pinning is digest-anchored.
