# Plan A — Test Overhaul (lead author: Claude)

> One of three independent source plans. Synthesis happens after two adversarial
> rounds. Plan-only — no implementation in this artifact.

## 0. Premise

This repo conflates **lints** with **tests**. `tests/unit/*.sh` are `yq`/`grep`
assertions over committed YAML/terraform — they prove a manifest *says* something, not
that the thing *works*. `chainsaw` runs on **kind** with a fake cloud, so it only
proves composition render + k8s admission (syntax/validity). The real-AWS chainsaw is
gated off and, even when run, uses static/admin creds — not the restricted Crossplane
**IRSA role**. Net: the class "we told the platform to create X but it never actually
created it / it doesn't work" is invisible until a downstream dependent trips over it,
live. auto-012 paid for this with **8 blockers found one-at-a-time live**
(OI-2026-06-07-6).

**Fix:** a layered architecture where **behavioral verification against a REAL cluster,
with Crossplane running under the real IRSA role**, is **on by default and coupled to
cluster bring-up**, augmented with **negative** and **precondition** tests; expensive
resources verified **after the fact**, cheap resources **both** verified after-the-fact
**and** instantiated-on-purpose.

## 1. Test taxonomy (name honestly)

- **L0 — LINT (static).** Existing `yq`/`grep` + kubeconform + helm-template asserts.
  Rename `tests/unit/` → `tests/lint/` (or relabel) so nobody mistakes a lint for a
  test. Fast, every commit. Necessary, never sufficient.
- **L1 — RENDER/ADMIT (kind).** chainsaw-on-kind = composition render + v2 admission.
  A fast **pre-flight** only; a green L1 is never evidence the thing builds.
- **L2 — LIVE BEHAVIORAL (real cluster, real IRSA).** The new core. Two sub-modes:
  - **L2a — after-the-fact verification** of expensive/standing resources created by
    bring-up (the mgmt + spoke EKS clusters, the bootstrap stack): assert the real
    thing exists and is correctly configured.
  - **L2b — instantiate-and-verify** for anything cheap enough: the test *creates* a
    real instance (IAM role, OIDC provider, S3, secret, ESO ExternalSecret, ConfigMap,
    ArgoCD cluster registration, DNS record), asserts the real cloud/cluster state,
    then tears it down.
- **L3 — NEGATIVE / PRECONDITION.** Improper/incomplete inputs are *rejected* (XRD
  schema + admission + composition guards), and units enforce their own preconditions
  (Keycloak must not start without its DB; ingress must not report ready without a
  cert; external-dns must fail visibly without its role).
- **L4 — E2E FLOW.** hub→spoke registration → `https://hello.platform.<domain>` 200 →
  Keycloak boots against RDS. The integration path that contained 6 of the 8 blockers.

## 2. The "every cluster bring-up runs it" mechanism

- A single entrypoint — `scripts/verify-platform.sh` (or a `make verify`) — runs
  **L0→L4 in order**, invoked automatically at the **end of every apply-and-verify /
  cluster bring-up**, and runnable on demand during dev.
- **On by default.** Disable only via an explicit, documented switch
  (`PLATFORM_VERIFY=off`, or per-layer `SKIP_L2=1`), **not set now**. A CI **skip-guard**
  asserts the disable flag is unset on protected branches, so "disabled by default" can
  never silently regress.
- Runs against the **live cluster we actually build**, under the **real IRSA roles** —
  that is the entire point. (Executes in CI / the cluster context, not the CA-blocked
  sandbox.)
- **Coupling discipline:** authoring a create-step REQUIRES adding/extending its
  L2/L3 test in the same change; bring-up runs it; "done" == green.

## 3. Slow-vs-cheap policy

- **Expensive (EKS cluster ~20 min, or any resource > ~5 min / non-trivial $):**
  **L2a after-the-fact only.** Bring-up creates it once; the verifier asserts the full
  desired shape (e.g. EKS: ACTIVE, nodegroup ACTIVE, addons, `authenticationMode:
  API_AND_CONFIG_MAP`, access entries present, OIDC provider exists, ELB subnet tags,
  hub→spoke SG reachability). **No throwaway EKS per test.**
- **Cheap (IAM role/policy, OIDC provider, S3, secret, ConfigMap, ESO ExternalSecret,
  ArgoCD cluster registration, DNS record):** **L2b instantiate-and-verify with
  teardown** PLUS L2a after-the-fact for the standing instances.
- **Medium (RDS ~5–10 min):** default to L2a after-the-fact on the standing
  `keycloak-db`; an opt-in L2b ephemeral-instance test behind a flag for when the
  Composition itself changes.

## 4. Negative + precondition tests (the always-always-always stuff)

- **Per XRD:** apply claims with missing-required / out-of-pattern fields → assert
  **rejected** by schema/admission (proves the contract; complements "field was never
  set" by making the contract enforceable).
- **Per IRSA/policy:** a **permission-completeness probe** that exercises each MR
  kind's full lifecycle (create/observe/update/delete/tag) **under the real crossplane
  IRSA role** — this is the single highest-value addition; it catches the entire
  auto-012 IAM class at authoring time.
- **Per workload precondition:** assert the GUARD fires — Keycloak Deployment stays
  NotReady/crashloops (does *not* report healthy) when the DB secret is absent or the
  DB is unreachable; ingress does not serve 200 without a valid cert; external-dns
  surfaces an auth error (and writes no records) without its role.

## 5. Coverage matrix — each auto-012 blocker → the layer that now catches it

| Blocker | Caught by |
|---|---|
| EKS `authenticationMode` CONFIG_MAP | L2a (assert API_AND_CONFIG_MAP) + L4 (AccessEntry create fails) |
| crossplane missing iam:Tag/Update/Get + rds:* | **L3 permission-completeness probe under real IRSA** (+ L2b instantiate) |
| ArgoCD controller SA no IRSA | L2a (assert BOTH SAs annotated) + L4 (spoke sync fails) |
| platform-spoke AppProject missing IngressClass | L2b/L4 (sync an IngressClass to the spoke) |
| shared-VPC subnet tags | L2a (assert tags) + L4 (NLB actually provisions) |
| external-dns SA-name ≠ trust subject | L2b/L4 (external-dns actually writes a record) + L3 (assume-role smoke) |

## 6. Tooling

- Re-point chainsaw (or add a `kuttl`/integration harness) at a **real cluster** for
  L2/L4, Crossplane under real IRSA; keep kind chainsaw strictly as L1.
- Make the existing **`crossplane-claim-verify`** skill the **mandatory** L2 verifier
  for every claim/XR (it already waits Synced/Ready + verifies the cloud resource).
- Expand `[mgmt] e2e-verify` into the L2a verifier (both ArgoCD SAs, spoke registration
  `connectionState`, subnet tags, SG reachability, access entries, OIDC).
- Workload preconditions (L3) via real deploy + readiness/negative assertions.
- The **skip-guard** CI check enforcing on-by-default.

## 7. Cost / time controls

- Reuse the standing mgmt cluster; parallelize L2b; per-layer timeouts via
  `scripts/wait-for-claim.sh`. The only ~20-min cost (EKS) is amortized into the real
  bring-up (L2a), never per-test.
- **Ephemeral-account reality is an asset here:** the suite runs as part of each
  rebuild we already do, so the marginal cost over the rebuild is small.
- Per-run-ID resource prefixing + a guaranteed cleanup trap (the chainsaw pattern) for
  L2b isolation.

## 8. Rollout phases

- **P1:** honesty rename + skip-guard + wire `verify-platform.sh` into apply-and-verify;
  expand e2e-verify into real L2a. (Immediate, cheap, high value.)
- **P2:** L2b instantiate-and-verify per cheap MR kind + make crossplane-claim-verify
  mandatory + the IRSA permission-completeness probe (L3).
- **P3:** L3 negative/precondition tests per XRD + per workload.
- **P4:** L4 hub→spoke e2e.
- Every phase adds tests **coupled** to the components it covers; nothing is deferred to
  a "nightly."

## 9. Risks / open questions

- Live-cluster test isolation (namespacing, prefixing, cleanup) — adopt the chainsaw
  per-run-ID prefix + cleanup trap.
- Real-cloud latency flakiness — bounded waits + retries, never `|| true`.
- Where the "dev cluster" comes from on a fresh account (answer: the mgmt cluster we
  always build first — the verifier runs as the last step of that build).
- L2b cost ceiling for medium resources (RDS) — start L2a-only, add ephemeral L2b
  behind a flag.
- Disable-switch governance: who may set `PLATFORM_VERIFY=off` and the audit trail.
