---
status: stable
---

# Onboard a tenant

What it takes, **today**, for a new team to get a namespace, deploy
rights, and repository wiring on this platform. This page documents
the platform as it is: onboarding is currently an
**operator-mediated procedure**, not a self-service product operation.
The gaps are named explicitly rather than papered over — discovering
whether that is acceptable is one of the scenario corpus's jobs.

## What "onboarded" means here

A tenant is onboarded when:

1. their application manifests are **admitted** by the platform's
   GitOps boundary (the `platform-spoke` project),
2. their workload has a **namespace** on a spoke cluster, and
3. their changes flow through **pull requests** that reconcile
   automatically after merge.

## The procedure (operator + tenant)

**1. Repository access (operator).** The tenant's engineers get write
access (or a fork-and-PR flow) on the platform repository. All tenant
delivery currently rides this repository.

**2. Source wiring — only if deploying from another repo (operator).**
The GitOps boundary admits sources from an exact allowlist. If the
tenant's chart lives outside the platform repository, the operator
adds that repository's exact URL to the `platform-spoke` project's
`sourceRepos` in `argocd/projects/platform-spoke.yaml` (a reviewed PR;
wildcards are rejected by CI). If the tenant's chart lives in the
platform repository — the common case today — nothing to do.

**3. Application + namespace (tenant PR, operator merge).** The tenant
follows [Deploy an application](deploy-an-application.md): chart under
`platform-services/<app>/`, ApplicationSet under
`argocd/apps/spoke/<app>.yaml` targeting `project: platform-spoke`,
with `CreateNamespace=true`. The namespace comes into existence on
first sync — there is no separate namespace-request step.

**4. Verify (tenant).** After merge:
[check health and find the URL](check-health-and-find-url.md).

## What a tenant can and cannot do afterwards

The boundary is the `platform-spoke` project —
[Tenant boundaries](../reference/tenant-boundaries.md) is the exact
contract. Summary: workload kinds into any namespace on spoke
clusters, from allowlisted repos only, never onto the management
cluster, cluster-scoped kinds only from the enumerated whitelist.

## Named gaps (the honest part)

!!! info "Where onboarding is owner hand-work today"
    - **No tenant self-service**: every onboarding step above requires
      a platform-operator action (repo access, allowlist changes,
      merges). There is no request flow, no tenant portal, no
      automation around it.
    - **No per-tenant isolation between tenants**: all tenants share
      the `platform-spoke` project and can, in principle, address each
      other's namespaces in manifests. Per-tenant projects/namespaces
      with RBAC fencing are the natural hardening and do not exist yet.
    - **No human `kubectl` access path**: tenants interact through
      Git and through whatever cluster access the operator grants by
      hand. The documented access story (directory group → kubectl)
      arrives with the platform's identity phase.
    - **Offboarding** is the reverse procedure (delete the Application
      file, prune runs; remove repo access) and is equally manual.

Scenario authors: file findings against these as product gaps, not
docs gaps — this page describes the implementation faithfully.
