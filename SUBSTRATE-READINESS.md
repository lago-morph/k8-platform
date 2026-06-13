# SUBSTRATE-READINESS.md — the definition of "done" for the platform bring-up

This file exists because "done" kept meaning *"I made the live symptom go away with a
hand-fix"* instead of *"the committed code produces a working platform from nothing."*
Those are different, and conflating them is why the same gaps keep biting on every
fresh account.

This is a **gate, not a wish.** An item is DONE only when its **Clean-build evidence**
column holds a verifiable pointer. No pointer ⇒ the status is
`pending clean-build verification` — never "done", "fixed", "works", or "proven".

---

## Definition of done (the only one)

> A build from **committed `main`** — terraform phases 0→1 via CI `apply-and-verify`,
> then the spoke via **ArgoCD GitOps** synced from committed `main` — brings up
> **hub Ready + spoke Ready + `hello.platform.<domain>` → HTTP 200 (valid public cert)**,
> with **ZERO manual steps**.

The substrate is not done until that is true and captured with evidence below.

## What counts as a manual step (i.e. a FAILURE of the definition)

If a clean bring-up needs **any** of these, it is **not** done — the thing that
required the step is an open blocker, not a closed issue:

- An inline IAM policy / `aws iam put-role-policy` to make a controller work.
- `aws ec2 authorize-security-group-ingress` (hub→spoke or otherwise).
- `aws ec2 create-tags` on subnets.
- A hand `kubectl apply` / `kubectl create namespace` of anything ArgoCD/Crossplane
  should own.
- An `argocd app set` / `kubectl patch` overlay of a placeholder value.
- Pausing or `ignoreDifferences`-ing `bootstrap` to make an overlay stick.
- Hand-registering the spoke cluster Secret with ArgoCD.

## What counts as Clean-build evidence (the only thing that earns a checkmark)

- A **CI run ID** of `terraform-test.yml apply-and-verify` from the committed branch
  (the IAM/terraform layer), **AND**
- a **GitOps sync from committed `main`/the branch** (no out-of-band patches), **AND**
- the relevant **behavioral check passing on that build** (the live-suite check or a
  recorded `kubectl`/`curl` result).

A live hand-fix is **NOT** evidence. It validates the *mechanism*, never the *artifact*.

---

## The readiness checklist

**Clean build #3 — 2026-06-12, fresh account `798802785871`** <!-- noqa: account-id - run provenance, account rotates -->
**(third consecutive from-scratch build; first with the full keycloak stack).**
Source: merged `main` (`0dd6114` = post-PR-#227). Build chain: base = CI run
**27429951073**, management = CI run **27430525986** (both `apply-and-verify`
green; the credential probe **27429228144** first confirmed the GHA secrets
resolve to the new account) → `platform-cluster-claim` synced from `main`
(`argocd app sync --core` via the SSM relay; XR Ready ~21 min) →
`spoke-access` synced from `main`, **no patches** (registration Secret
complete on its own, full ADR-0010 contract). Oracles on this build:
`hello-e2e-live.sh` PASS (HTTP 200 first poll), `spoke-cluster-secret-live.sh`
PASS, `sandbox-kubectl-relay.sh` (spoke, 2 Ready) PASS, `rds-instance-live.sh`
PASS (instance in the BASE VPC — the OI-2026-06-11-1 CREATE-path close; the
oracle's own bool-case false negative fixed in #235), **and NEW:
`keycloak-e2e-live.sh` PASS** — Keycloak booted against RDS through the spoke
ingress (https OIDC issuer; the OI-2026-06-07-5 behavioral close). The
keycloak first boot surfaced four committed defects; per the
code-not-hands loop each was fixed in code with a red-first unit test and
merged mid-build (#231 admin-ES revert gap, #232 realm-JSON comment fields,
#233 placeholder IdP URLs, #234 KC_HOSTNAME https issuer), reaching the
spoke by GitOps propagation only. Zero manual steps; operator inputs were
the two designed deliberate-sync gates.

**Clean build #2 — 2026-06-11, fresh account `608553548146`** <!-- noqa: account-id - run provenance, account rotates -->
**(the green-twice gate is now satisfied).** Source: merged `main`
(`582761f`), no mid-build merges needed for the gate rows. Build chain:
base = CI run **27379934113**, management = CI run **27380296208** (both
`apply-and-verify`, green), spoke = ArgoCD sync of `platform-cluster-claim`
from `main` (XR `platform` Ready=True in ~14 min) then `spoke-access` from
`main` with **no oidcIssuer patch** (the Observe path supplied it; the
registration Secret appeared complete on its own ~3 min after sync — all 3
labels + all 5 contract annotations). Terminal state:
`https://hello.platform.<domain>` → **HTTP 200, verified public chain**
(first poll), with the committed oracles passing on this build:
`hello-e2e-live.sh` PASS, `spoke-cluster-secret-live.sh` PASS,
`sandbox-kubectl-relay.sh` (spoke, 2 Ready nodes) PASS. Zero manual steps;
the only operator inputs were the two designed deliberate-sync gates.
New on this build: the `keycloak-db` XDatabase auto-synced and **provisioned
RDS from scratch under the fully narrowed IAM policy** (XR Ready=True,
`rds-instance-live.sh` PASS) — rows 6 and 7 earn their first CREATE-path
evidence. The build loop also caught a NEW defect (**OI-2026-06-11-1**: the
RDS Instance lands in the account DEFAULT VPC — unreachable from the
platform clusters; durable Composition+EnvironmentConfig fix authored in PR
#226, the same code-not-hands loop as OI-2026-06-10-1 on build #1).

**Clean build #1 — 2026-06-10, fresh account `341221860475`** <!-- noqa: account-id - run provenance, account rotates -->
**(the first ever from-scratch build with zero manual steps).** Source: merged
`main` (`a68b858` = PRs #220/#221/#222 + prior; the mid-build Composition fix
#223 `c8fddb8` reached the hub by GitOps propagation, not hand-edit). Build
chain: base = CI run **27305258998**, management = CI run **27305788371**
(both `apply-and-verify`, green), spoke = ArgoCD sync of
`platform-cluster-claim` then `spoke-access` from committed `main` (the two
designed deliberate-sync gates; **no value overlays, no REST registration, no
aws-CLI mutations, no kubectl applies**). Terminal state:
`https://hello.platform.<domain>` → **HTTP 200, verified public chain**, with
the committed oracles passing on this build: `hello-e2e-live.sh` PASS,
`spoke-cluster-secret-live.sh` PASS, `sandbox-kubectl-relay.sh` (spoke) PASS.

| # | Item / known gap | Durable fix | Clean-build evidence | Status |
|---|---|---|---|---|
| 1 | EKS service-linked-role `iam:GetRole` (zero-node spoke) | PR #213 (committed `irsa.tf`) | Builds #1–#3: the spoke nodegroup created from scratch under the committed narrowed policy on three consecutive fresh accounts — 2 Ready nodes each (`sandbox-kubectl-relay.sh` PASS all three). (The earlier auto-016 "VALIDATED" stays retracted — see `retrospective/2026-06-09-214-a.md`.) | **DONE (3× clean build)** |
| 2 | Hub→spoke EKS-API SG 443 (OI-2026-06-07-4) | `hub-eks-api-ingress` classic SecurityGroupRule (PR #221) | Builds #1–#3: hub ArgoCD synced every spoke-* Application on the spoke's private endpoint with zero SG hand-fixes on all three accounts; `hello-e2e-live.sh` asserts `spoke-hello` Synced+Healthy from the hub (PASS all three). | **DONE (3× clean build)** |
| 3 | Shared ELB subnet tags (OI-2026-06-07-3) | terraform/base `hosted_cluster_names` tags (PR #222) | Builds #1–#3: the spoke ingress NLB provisioned in the shared subnets with zero `create-tags` hand-fixes on all three accounts (hello 200 terminates on that NLB with the spoke's ACM cert). | **DONE (3× clean build)** |
| 4 | Placeholder overlays vs bootstrap selfHeal (OI-2026-06-07-2, **ADR-0010**) | ApplicationSets consumer half (PR #218) + row-5 producer | Builds #1–#3: all seven ApplicationSets generated from the registration Secret's contract annotations on all three accounts; spoke-hello/-ingress-nginx/-external-dns Synced+Healthy with **no hand overlay anywhere**. | **DONE (3× clean build)** |
| 5 | Spoke ArgoCD cluster-Secret durable form (OI-2026-06-07-1) | ADR-0010 PR-2 producer (PR #220; retires the spec.oidcIssuer overlay) | Builds #1–#3: `platform-spoke` Secret produced by the Composition (Observe→writer Objects), full contract real on all three accounts; `spoke-cluster-secret-live.sh` PASS all three; ArgoCD connection Successful (apps synced through it). | **DONE (3× clean build)** |
| 6 | RDS narrowing safe on the CREATE path (#211) | PR #211 (committed) | Clean build #2: `keycloak-db` auto-synced from `main` and provisioned RDS from scratch under the narrowed policy (XR Synced+Ready=True ~10 min, `rds-instance-live.sh` PASS, instance `available`). Caveat (build #2): the instance landed in the DEFAULT VPC (OI-2026-06-11-1). Build #3: fresh CREATE landed directly in the BASE VPC under the merged #226/#227 fix (`rds-instance-live.sh` PASS after the #235 oracle bool fix) and Keycloak CONNECTS through it (`keycloak-e2e-live.sh` PASS — the OI-2026-06-07-5 close). | **DONE (2× clean build)** |
| 7 | EC2 narrowing safe on the CREATE path (#212) | PR #212 (committed) | Clean build #2: management run 27380296208 applied the EC2VpcScoped/EC2Unconditioned Sids; the spoke's kube-relay-ingress + hub-eks-api-ingress SecurityGroupRule MRs created under them (relay oracle PASS = the rules function; hub→spoke sync = the API rule functions). Build #3 (run 27430525986): same CREATE path green again, plus the XDatabase SecurityGroup + 5432 rule created from scratch (the rds:5432 path keycloak now traverses). | **DONE (2× clean build)** |
| 8 | Hello hub→spoke e2e (OI-2026-06-08-2) | PR #210 (check authored) | Builds #1–#3: PASS on all three accounts (HTTP 200 + body marker + hub-side `spoke-hello` Synced+Healthy; 1s to first 200 on builds #2+#3). | **DONE (3× clean build)** |
| 9 | Keycloak **boots** against RDS through the spoke ingress (OI-2026-06-07-5) | cross-cluster DB path (hub PushSecret → ASM → spoke ExternalSecret + extraEnvVarsSecret host/port) | Clean build #3: `keycloak-e2e-live.sh` PASS — realm imports, https OIDC discovery 200. Four first-boot defects fixed in code mid-build (#231–#234). | **DONE (1× clean build)** |
| 10 | Keycloak **federation live-wired** to Cognito (REQ-AUTH-02/08) | NOT YET BUILT — the `identityProviders` + `identityProviderMappers` blocks are deliberately ABSENT (removed in #233; placeholders fail Keycloak's import-time URL validation). Needs the issuer/auth/token/jwks/userInfo URLs sourced from terraform/base Cognito outputs and the confidential client secret delivered via the keycloak-oidc-clients secret chain — none committed. | none | **pending clean-build verification** (blocker — phase-5 identity half) |
| 11 | EKS clusters federate kubectl auth to Keycloak (REQ-AUTH-07/09/10) | NOT YET BUILT — no `aws_eks_identity_provider_config` (or its Crossplane equivalent) is composed for any cluster; the `kc:*` ClusterRoleBindings exist + are unit-tested but bind nothing until the IdP config lands. No federation oracle exists (the Cognito→Keycloak→kubectl path is untested end to end). | none | **pending clean-build verification** (blocker — phase-5 identity half) |

Clean build #1 also caught and durably fixed a NEW defect mid-build —
**OI-2026-06-10-1** (ACM provider v2.5.0 leaves the Certificate external-name
empty; `certificateArnSelector` could never resolve; fixed in PR #223 by
routing the ARN through the composite) — which is the build loop working as
designed: the failure produced a code fix, not a hand-fix.

**No row may flip to DONE without filling its evidence column.** The agent does not
get to assert these are fixed; you (or anyone) can audit each one by clicking the
run ID.

---

## The order of operations to actually finish

1. ~~Build the four missing durable fixes (#2–#5).~~ **DONE** (PRs #218/#220/#221/#222).
2. ~~Integration branch + rebuild from committed source with ZERO manual steps.~~
   **DONE ONCE** — clean build #1 above (2026-06-10). The mid-build defect it
   caught (OI-2026-06-10-1) was fixed in code (PR #223) and converged by GitOps.
3. ~~Second green clean build.~~ **DONE** — clean build #2 above (2026-06-11,
   account 608553548146): same recipe, zero manual steps, all three oracles <!-- noqa: account-id - run provenance, account rotates -->
   PASS. **The green-twice posture gate is satisfied.**
4. ~~Rows 6/7 (RDS/EC2 narrowing on the CREATE path) + OI-2026-06-07-5
   keycloak DB path.~~ **DONE** — clean build #3 (2026-06-12, account
   798802785871): RDS in the base VPC, Keycloak boots against it, row 9 <!-- noqa: account-id - run provenance, account rotates -->
   earned. Rows 6/7 now 2×.
5. **Phase-5 identity half (rows 10/11) — the remaining unbuilt feature.**
   The Cognito broker block and the EKS `IdentityProviderConfig` do not
   exist yet; until they do, "phase 5" means "Keycloak runs", not "humans
   get kubectl access from their directory group". This is the headline
   next feature.
6. Then resume the test-overhaul work (SKIP-kind flips, the live-evidence
   producer green so the PR gate flips, Track B) — unblocked by the
   in-platform material chain (the live-verify producer).

A fix that cannot be validated this way stays `pending clean-build
verification` and is carried as a **blocker**, not silently deferred into the
open-issues graveyard.
