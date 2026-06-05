# auto-005 session plan (CORRECTED mandate) — long-run-BYIB6

**Supersedes the scope of `auto-005-scope-envelope.md`.** That envelope wrongly
bounded the live build OUT (assuming stale creds). The user corrected:
credentials are **current**; the mandate is to **build phases 0→3 and then work
in the live environment**, building everything already tested, and to plan the
session while long builds run. See AGENTS §8.5/§8.6 (recorded this session).

---

## Mandate

Bring up the full stack on the live (current) account, then build the phase-3
hub-spoke live:

1. Phase 0 (base) — VPC, subnets, Route53, Cognito, base ACM wildcard, state backend.
2. Phase 1 (management) — EKS mgmt cluster (~20 min), ArgoCD (+ Terraform-output
   creds, PR #141), Crossplane core + providers (family-aws, secretsmanager, eks,
   iam, acm, route53) + functions (patch-and-transform, environment-configs), ESO,
   Kyverno, IRSA (incl. ACM+Route53), the `cluster-network` EnvironmentConfig,
   ArgoCD app-of-apps bootstrap.
3. Phase 2 (XRDs) — verify via `chainsaw.yml` full set (PlatformSecret e2e +
   platform-cluster `xrd-establishes`).
4. Phase 3 (cluster+cert) — sync the `platform-cluster-claim` ArgoCD Application
   (drive via the Terraform-output ArgoCD cred, AGENTS §10.1) → platform EKS
   cluster + DNS-validated wildcard ACM cert (~20 min). Verify `status.certificateArn`
   + `CertificateValidation` Ready.
5. Phase 3 spoke (LIVE) — hub-spoke registration, `platform-services/{ingress,
   external-dns}`, hello app, an ArgoCD ApplicationSet; verify
   `https://hello.platform.<domain>` resolves with valid TLS (REQ-PLAT-02/03/04/06).

## Build pipeline status (this session)

| Step | Dispatch | Run | State |
|---|---|---|---|
| Phase 0 base | `terraform-test.yml phase=base action=apply-and-verify` @ `main` | 27021589131 | dispatched (in_progress) |
| Phase 1 mgmt | `phase=management action=apply-and-verify` | — | **after phase 0 green** (the ~20-min long pole) |
| Phase 2 chainsaw | `chainsaw.yml` (full set) | — | after phase 1 green |
| Phase 3 cluster | ArgoCD sync `platform-cluster-claim` via §10.1 cred | — | after phase 2 |
| Phase 3 spoke | live build | — | after phase 3 cluster Ready |

Credentials confirmed current by the user (2026-06-05). I will re-confirm
myself via Actions per §8.5 (apply-and-verify fails fast on bad creds).

## Work to do WHILE the builds run (no dependency on in-flight applies)

- This plan + AGENTS §8.5/§8.6 (done).
- Prep the phase-3 spoke artifacts that don't need live feedback yet: scaffold
  `platform-services/ingress` and `platform-services/external-dns` Helm values +
  the hello app manifests, and the ArgoCD ApplicationSet, so they are ready to
  apply the moment the platform cluster is Ready. The cross-cluster cert-ARN
  injection + ephemeral-domain wiring need live convergence (handoff §D) — those
  get finalized live, not blind.
- Resolve PR #142's chainsaw-verify red: since creds are current, dispatch
  `chainsaw.yml` against the branch HEAD once chainsaw-touching commits settle
  (this both greens #142 and is the phase-2 verification).

## Already landed this session (pushed, on `claude/long-run-BYIB6`)

- ASM cleanup-trap fix + behavioral unit test (OI-2026-05-28-1).
- pipefail+grep-q SIGPIPE flake fix across the unit suite (OI-2026-06-05-1, 0/30).
- Handoff staleness corrections; auto-006 external-name brief (Round 1).

## Phase-3 spoke execution plan (do LIVE once the platform cluster is Ready)

The `XPlatformCluster` XR publishes on `status`: `clusterArn`, `endpoint`,
`oidcIssuer`, `nodeGroupArn`, `certificateArn` (the issued `*.platform.<domain>`
ACM ARN), and the DNS-validation record fields. The cluster Composition does
NOT create the cluster's own OIDC provider or the external-dns IAM role (XRD
header note) — the spoke must add those. Steps, in order:

1. **Spoke registration (REQ-PLAT-02).** Register the platform EKS cluster with
   the management ArgoCD as a spoke. Kubeconfig endpoint/CA come from the EKS
   **Cluster MR's own connection secret** (v2 removed the XR-level secret); auth
   via an EKS access entry / IRSA for the ArgoCD application-controller. Create
   an `argocd.argoproj.io/secret-type: cluster` Secret in `argocd`. Drive from
   CI using the §10.1 Terraform-output ArgoCD credential. **Live-coupled** (real
   endpoint/CA/token).
2. **OIDC provider + external-dns IRSA (supports REQ-PLAT-04).** Create the
   `aws_iam_openid_connect_provider` for the platform cluster (issuer =
   `status.oidcIssuer`) and an external-dns IAM role scoped to the zone. Either
   Crossplane MRs (iam provider already installed) on the hub, or a small
   terraform addition. **Live-coupled** (issuer + thumbprint).
3. **ingress-nginx (REQ-PLAT-03).** Helm release on the spoke: internet-facing
   NLB, `aws-load-balancer-type: nlb`, TLS terminated at the NLB via
   `service.beta.kubernetes.io/aws-load-balancer-ssl-cert: <status.certificateArn>`,
   ssl-ports=443, backend http (mirrors the management cluster's pattern that
   `test_helm_render.sh` already asserts). **cert ARN is cross-cluster** — inject
   from the XR `status.certificateArn` into the spoke ingress values (ApplicationSet
   param or a sync pre-hook). Design finalized live.
4. **ExternalDNS (REQ-PLAT-04).** Helm release scoped to `--domain-filter=platform.<domain>`,
   `--source=ingress`, `--policy=upsert-only`, `--provider=aws`, IRSA = the role
   from step 2. (`test_helm_render.sh` already asserts these args for the mgmt
   instance — reuse the shape.)
5. **Hello app (REQ-PLAT-06).** Deployment + Service + Ingress at
   `hello.platform.<domain>` (host is ephemeral-domain-coupled). ExternalDNS
   creates the Route53 record; the NLB serves it under the wildcard ACM cert.
6. **ArgoCD ApplicationSet/Apps** targeting the spoke cluster deploy steps 3-5.
7. **Verify (REQ-PLAT-06):** `curl -v https://hello.platform.<domain>` returns
   200 with a valid (ACM-issued, not self-signed) cert chain, no manual DNS/cert
   steps. Build this live with convergence feedback (handoff §D, AGENTS §6.17) —
   the cross-cluster cert-ARN handoff + ephemeral-domain substitution + spoke
   registration are the parts that must be confirmed against the live cluster,
   not authored blind.

## Stop conditions (unchanged)

Account constraint missing, destructive op outside scope, hard dependency
failure, or explicit user countermand. Building is the default; do not stop to
ask when the next step is "build the next tested phase."
