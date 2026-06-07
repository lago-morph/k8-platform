# auto-012 — Scope envelope (unattended run, 2026-06-07)

**Mode:** autonomous-run skill. User is structurally absent (webhook-delegated).
This envelope is the fallback contract; work proceeds without waiting.

**Branch policy deviation (explicit task instruction overrides skill default):**
the task pins all work to a single branch `claude/k8s-platform-phase3-5-m9evX`
with "NEVER push to a different branch without explicit permission." I therefore
do NOT use stacked sub-branches; I make well-structured commits on this one
branch and open a single PR to `main`. Rewindability is preserved per-commit
(SHAs listed in the run summary) rather than per-PR.

**Inherited live state (verified this run, 2026-06-07):** account 596430611165,
us-east-1. Both EKS clusters ACTIVE (`k8-platform-mgmt`, `k8-platform-services`).
ArgoCD reachable + logged in. Spoke OIDC issuer published on
`XPlatformCluster.status.oidcIssuer`; ACM `*.platform.<domain>` ISSUED; spoke
nodegroup ACTIVE.

## 1. What I plan to do

- **Fix the spoke-cluster auth-mode blocker** (newly discovered): the spoke EKS
  cluster is `authenticationMode: CONFIG_MAP`; EKS AccessEntries (the entire
  hub→spoke trust mechanism) cannot be created until it is `API_AND_CONFIG_MAP`.
  Patch the platform-cluster Composition's Cluster MR `accessConfig`, with a
  regression test (§6.2).
- **Phase-3 spoke trust plane:** overlay the live `oidcIssuer` onto the
  `spoke-access` XR and sync it → OIDC provider + external-dns IRSA Role/RolePolicy
  + EKS AccessEntry/AccessPolicyAssociation. Verify the AWS resources exist.
- **Register the `platform-spoke` ArgoCD cluster Secret** from the EKS Cluster MR
  connection secret (provider-kubernetes + `hub` ProviderConfig), granting
  provider-kubernetes the RBAC to write the Secret (same class as the ESO fix).
- **Spoke app convergence:** overlay spoke values (certArn/domain/region/role) →
  ingress-nginx → external-dns → hello → verify
  `https://hello.platform.596430611165.realhandsonlabs.net` returns 200 with a
  valid ACM chain.
- **Phase 5:** sync the `keycloak-db` XDatabase XR → verify the RDS instance +
  connection secret + that Keycloak consumes it.
- Keep `ai/handoff.md`, `docs/open-issues.md`, a run summary, and a
  self-retrospective current.

## 2. What I plan to NOT do

- Not rebuild phases 0/1 or the management cluster, or the already-ACTIVE spoke
  EKS cluster (only an in-place accessConfig update on it).
- Not touch workload1-* apps (out of scope for this run).
- Not change static-token auth or any REQ-NF-03 invariant (exec/IRSA auth only).
- No teardown of any kind.

## 3. Scale estimate

One branch / one PR to `main`; ~6–10 commits. 2–4 adversarial-review subagents at
test-drafting points. Live ArgoCD syncs + AWS verification interleaved. Duration:
several hours (RDS + cluster reconcile waits dominate).

## 4. First decision points

- **accessConfig change on a live cluster.** Best answer: set
  `authenticationMode: API_AND_CONFIG_MAP` + `bootstrapClusterCreatorAdminPermissions`
  unchanged; this is an allowed in-place EKS upgrade (CONFIG_MAP→API_AND_CONFIG_MAP
  is one-way but non-destructive). Alternative: API-only (riskier, drops aws-auth
  configmap). Rewind: revert the composition commit; cluster stays
  API_AND_CONFIG_MAP (harmless superset).
- **oidcIssuer overlay mechanism.** Best answer: sync `spoke-access` (applies the
  git placeholder + creates MRs), then patch the live XR's `spec.oidcIssuer` to the
  real value via provider-kubernetes/CI; manual-sync app tolerates the resulting
  drift (value is account-ephemeral, §8.1, uncommittable). Alternative: redesign the
  Composition to derive the issuer from a cross-XR reference (rejected — AGENTS §2,
  the spec chose the overlay approach). Rewind: delete the XSpokeAccess XR.
- **provider-kubernetes RBAC for the cluster Secret.** Best answer: add a
  ClusterRole/Binding granting the provider-kubernetes SA secret write in `argocd`
  ns, same class as the ESO ClusterRole fix (#160). Rewind: revert that manifest.

## 5. Morning-review items (surfaced, not auto-decided)

- Any AWS resource that fails to provision after a defensible number of retries
  (logged to `docs/open-issues.md` with diagnosis).
- The cluster XR `Ready=False/Creating` residual, if it does not resolve.

## 6. Stop conditions

Context-budget approaching exhaustion; auth/GitHub hard-failure; a destructive op
outside scope becoming required; or all deliverables done. Otherwise: keep going.
