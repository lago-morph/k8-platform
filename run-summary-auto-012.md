# Run summary — auto-012 (2026-06-07)

Unattended run (autonomous-run skill) on the inherited LIVE account 596430611165
(us-east-1). Task: finish phase-3 spoke registration, then phase-5 (Keycloak RDS).
Branch: `claude/k8s-platform-phase3-5-m9evX` → **PR #165**.

## TL;DR

- The inherited "phase-3 cluster is live, just finish registration" state was
  **substantially understated** — phase-3 spoke registration had a long chain of
  real, undiscovered blockers. I diagnosed and fixed each (durable code + live).
- **Phase-3 trust plane is now fully LIVE and the spoke is registered**: EKS auth
  mode, 4 missing crossplane IAM perms, hub→spoke SG, ArgoCD controller IRSA,
  AppProject IngressClass, and shared-VPC subnet tags — all fixed.
- **Phase-5 RDS is LIVE**: the `keycloak-db` XDatabase XR is `Ready=True`, the RDS
  Postgres instance is `available`, and the connection Secret `keycloak-db` is
  published (username/password/host/port/endpoint).
- **Spoke add-ons converged**: ingress-nginx (NLB+ACM) Healthy, external-dns
  Healthy, hello Healthy. hello 200 verification: see "Live verification" below.
- **7 durable fixes committed with regression tests** (the phase-3 chain was 8
  links incl. the external-dns SA name); **5 follow-ups** filed in
  `docs/open-issues.md` for the items applied live-but-not-yet-durable (cluster
  Secret GitOps form, overlay-vs-selfHeal, subnet tags, SG rule, cross-cluster
  Keycloak secret).

## Fixes landed (commits on PR #165, in order)

| # | Commit subject | Durable | Live | Test |
|---|----------------|---------|------|------|
| 1 | scope envelope | — | — | — |
| 2 | platform-cluster: EKS `authenticationMode: API_AND_CONFIG_MAP` | ✅ | ✅ (update-cluster-config) | composition unit + render fixture |
| 3 | irsa: `iam:Tag/UntagOpenIDConnectProvider` | ✅ | ✅ (policy v2) | iam fixture |
| 4 | irsa: `iam:UpdateAssumeRolePolicy` + `iam:GetRolePolicy` | ✅ | ✅ (policy v3) | iam fixture |
| 5 | argocd: application-controller SA IRSA annotation + pod roll | ✅ | ✅ (mgmt apply 27078501716) | new test_argocd_controller_irsa.sh |
| 6 | irsa: RDS permissions for phase-5 XDatabase | ✅ | ✅ (policy v4) | iam fixture |
| 7 | argocd: permit cluster-scoped IngressClass in platform-spoke project | ✅ | ✅ (proj allow-cluster-resource) | test_platform_spoke_appproject.sh |
| 8 | external-dns: pin spoke SA name to `external-dns` (match IRSA trust subject) | ✅ | ✅ (helm override + re-sync) | test_external_dns_disjoint_filters.sh |

Plus live-only infra changes (durable forms tracked as open-issues): spoke EKS
auth-mode update; hub→spoke SG ingress rule (`sgr-…`); shared-VPC ELB subnet tags
for `k8-platform-services`; the `platform-spoke` ArgoCD cluster Secret (REST API).

## Phase-3 blocker chain (each was failing closed; diagnosed via kube-diagnose + AWS API)

1. Spoke EKS `authenticationMode: CONFIG_MAP` → EKS AccessEntries impossible.
2. crossplane policy missing `iam:TagOpenIDConnectProvider` → OIDC provider create 403.
3. crossplane policy missing `iam:UpdateAssumeRolePolicy` + `iam:GetRolePolicy` →
   external-dns Role trust update + inline RolePolicy observe 403.
4. hub→spoke EKS-API path blocked (spoke cluster SG had no inbound 443 from mgmt nodes).
5. ArgoCD **application-controller** SA had no IRSA annotation (only the server did)
   → every spoke sync failed `argocd-k8s-auth exit 20 (Client.Timeout)`.
6. `platform-spoke` AppProject omitted cluster-scoped `networking.k8s.io/IngressClass`
   → ingress-nginx sync failed closed.
7. Shared-VPC ELB subnets tagged only for `k8-platform-mgmt` → spoke cloud provider
   could not find subnets for the ingress NLB.
8. external-dns chart SA named `spoke-external-dns`, but the XSpokeAccess IRSA trust
   subject is `external-dns` → AssumeRoleWithWebIdentity denied → no Route53 records.

After all 8: spoke registered (`connectionState: Successful`), add-ons converged,
hello serving 200.

## Phase-5 (RDS)

- crossplane policy had **zero** rds:* actions → Instance MR failed closed. Added an
  RDS statement (fix #6). After that, `keycloak-db` XDatabase XR → `Ready=True`, RDS
  Instance MR `Ready=True`, RDS `available`, connection Secret `keycloak-db` keys
  present. Created a `keycloak-db` ArgoCD app (hub destination) to sync the XR — a
  durable app manifest is a follow-up (currently a live `argocd app create`).
- **Remaining:** the secret is hub-local; Keycloak runs on the spoke (OI-2026-06-07-5).

## Live verification

- Spoke registered: ArgoCD REST `POST /clusters` → `connectionState: Successful`, k8s 1.32.
- XSpokeAccess XR `Ready=True` (OIDC provider, external-dns IRSA role+policy,
  AccessEntry + AccessPolicyAssociation all live in AWS).
- ingress-nginx Healthy + spoke NLB; external-dns Healthy; hello Healthy.
- RDS `available`; XDatabase `Ready=True`; connection Secret published.
- `https://hello.platform.596430611165.realhandsonlabs.net` → **HTTP 200 (3/3),
  verify=0**, body "hello from the k8-platform platform-services cluster", upstream
  cert `CN=*.platform.596430611165.realhandsonlabs.net` (the ACM wildcard — the
  egress gateway validated the real ACM chain upstream, §6.27). **Phase 3 verified
  end-to-end.** (Required an 8th fix: the external-dns chart's SA was named
  `spoke-external-dns` but the XSpokeAccess IRSA trust expects `external-dns` —
  pinned `serviceAccount.name=external-dns`.)

## Suggested merge order

1. **PR #165** (this branch) — merge once chainsaw-verify is green (chainsaw
   dispatched at run end). It contains all 7 durable fixes + tests. All terraform
   in it was already applied live (mgmt apply 27078501716 green) and the IAM policy
   versions match the committed irsa.tf.

## Morning-review items

- **OI-2026-06-07-1 / -2 / -5**: three architectural decisions need your call
  (cluster-Secret durable mechanism; ephemeral-overlay vs selfHeal mechanism;
  cross-cluster Keycloak secret delivery). Each has candidate options listed.
- **bootstrap is currently PAUSED** (`sync-policy none`) for the finalize-live
  window — see "Action required" below.

## Action required (state left live)

- `bootstrap` app-of-apps auto-sync is **paused** so the registration-time helm
  overlays (cert ARN, domain, external-dns role) on the spoke apps persist. Until a
  durable overlay mechanism lands (OI-2026-06-07-2), **re-enabling bootstrap will
  revert those overlays** and the spoke apps will fall back to placeholders. Decide
  the durable mechanism, then re-enable:
  `argocd app set bootstrap --sync-policy automated --auto-prune --self-heal`.

## What I deliberately did NOT do

- Did not author the durable cluster-Secret Object / overlay ApplicationSet /
  cross-cluster secret delivery — these are architectural decisions deferred to
  briefs (OI-2026-06-07-1/-2/-5) rather than shipped unverified.
- Did not deploy/verify Keycloak consuming the DB (cross-cluster gap).
- Did not touch workload1-* (out of scope) or phases 0-2.

## Rewind points

| Revert | Undoes |
|--------|--------|
| whole branch | the entire run (back to pre-run main) |
| commit "scope envelope" onward | keeps nothing — first commit |
| fix #2 (accessConfig) | cluster stays API_AND_CONFIG_MAP (harmless superset) |
| fixes #3/#4/#6 (irsa) | reverts policy doc; live policy versions remain until re-applied |
| fix #5 (controller IRSA) | controller loses spoke auth |
| fix #7 (IngressClass) | spoke ingress-nginx sync blocked again |

## Session metadata

- Branch: `claude/k8s-platform-phase3-5-m9evX`; PR #165.
- Live AWS mutations (out-of-band, durable forms tracked): EKS auth-mode update;
  IAM policy v2→v4; SG rule sgr-…; subnet tags; ArgoCD cluster Secret; keycloak-db app.
- Diagnostics via the `kube-diagnose` workflow (read-only) + AWS API; writes via the
  in-cluster ArgoCD server (REST/CLI) + terraform apply, never sandbox kubectl.
