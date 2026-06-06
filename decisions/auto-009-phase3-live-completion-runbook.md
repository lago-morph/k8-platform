# auto-009 — Phase-3 live completion runbook (execute when platform cluster is Active)

**Purpose.** The exact, ordered live steps + manifests to finish phase 3 once the
platform EKS cluster exists. This is the "live-coupled" half deferred by auto-008.
It doubles as the morning next-step if the run ends before the cluster is Active.
Every account-derived value is read from the live API / Terraform state at run
time (AGENTS §8.1) — nothing here is a committed literal.

**Preconditions (verified this run):** account 730335382332; management cluster
`k8-platform-mgmt` ACTIVE (run 27035617598); ArgoCD at
`https://argocd.management.<domain>` (admin password = `terraform/management`
output `argocd_admin_password`, read from S3 state
`k8-platform/management/terraform.tfstate`). Sandbox tools: aws, argocd, helm,
kubectl (kube-API blocked by private CA — use ArgoCD/CI for kube ops), terraform.

---

## Step 1 — Sync the platform cluster XR (REQ-PLAT-01, REQ-PLAT-05)

ArgoCD-drive from the sandbox (handoff Phase-3 sync; manual-sync stays):
```sh
source /tmp/awsenv.sh
PW=$(aws s3 cp s3://k8-platform-tfstate-730335382332/k8-platform/management/terraform.tfstate - | jq -r '.outputs.argocd_admin_password.value')
argocd login argocd.management.<domain> --username admin --password "$PW" --grpc-web
argocd app get platform-cluster-claim          # confirm it exists (synced by bootstrap)
# Pre-check provider health (the cluster XR needs aws-eks + aws-route53 + aws-acm Healthy):
argocd app sync crossplane-resources           # ensure XRDs/compositions current
argocd app sync platform-cluster-claim         # provisions the platform EKS cluster + *.platform.<domain> ACM cert (~20 min)
```
Verify (AWS CLI, no kube-API needed):
```sh
aws eks describe-cluster --name k8-platform-services --query 'cluster.status'   # -> ACTIVE
aws acm list-certificates --query "CertificateSummaryList[?DomainName=='*.platform.<domain>']"
aws acm describe-certificate --certificate-arn <arn> --query 'Certificate.Status' # -> ISSUED
```
The XR publishes `status.certificateArn`, `status.oidcIssuer`, `status.endpoint`.
Read them from the XR (via `argocd app manifests` / a CI kubectl) for steps 2-4.

## Step 2 — provider-kubernetes (auto-008 C5; one-time mgmt change)

Writing the ArgoCD cluster Secret (hub-local) needs provider-kubernetes. Add to
`terraform/management` (Crossplane Provider + hub ProviderConfig using the
in-cluster SA), re-apply management (`phase=management action=apply-and-verify`).
This is a small, additive change — does NOT disturb phases 0-2.

## Step 3 — XSpokeAccess: OIDC provider + external-dns IRSA + ArgoCD access entry

A SEPARATE Composition (auto-008 C2 — NOT folded into the cluster Composition,
because P&T can't gate on the late-populated `status.oidcIssuer`). Consumes the
cluster XR's published status + the `cluster-network` EnvironmentConfig
(extended to carry `accountId` + the `${cluster_name}-argocd` role ARN — auto-008
C3). Modern family group `*.m.upbound.io`. MRs:

**3a. OIDC provider** (`iam.aws.m.upbound.io/v1beta1` OpenIDConnectProvider) —
thumbprint is the well-known Amazon root constant (auto-008 C1):
```yaml
spec.forProvider:
  url: <status.oidcIssuer>
  clientIdList: ["sts.amazonaws.com"]
  thumbprintList: ["9e99a48a9960b14926bb7f3b02e22da2b0ab7280"]
```

**3b. external-dns IRSA** — `iam.aws.m.upbound.io/v1beta1` Role + an INLINE
RolePolicy (auto-008 C4 — the crossplane IRSA has `iam:PutRolePolicy`, not
`iam:CreatePolicy`). Trust policy StringEquals on BOTH (auto-008 S2):
`<oidc>:sub = system:serviceaccount:external-dns:external-dns` and
`<oidc>:aud = sts.amazonaws.com`. Route53 inline policy scoped to the zone.

**3c. ArgoCD access entry** — `eks.aws.m.upbound.io/v1beta1` AccessEntry +
AccessPolicyAssociation: `principalArn` = the full `${cluster_name}-argocd` role
ARN (from the extended EnvironmentConfig), `policyArn =
arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy`,
`accessScope.type: cluster`. So the hub application-controller can sync to the
spoke (auto-008 S1 — backstopped by policies/audit/10-spoke-no-cluster-admin-binding).

Render fixtures + kubeconform schemas for each new MR kind (auto-008 C6).

## Step 4 — Register the spoke with ArgoCD

Build the ArgoCD cluster Secret from the EKS Cluster MR's connection secret
(endpoint + CA; v2 has no XR connection secret — auto-008/XRD lines 78-81), with
`aws`/exec auth using the argocd role (NO static token — REQ-NF-03). Labels:
`argocd.argoproj.io/secret-type: cluster`, `k8-platform.io/cluster-role: spoke`;
name `platform-spoke` (matches the Applications' `destination.name`). Annotate
`k8-platform.io/certificate-arn: <status.certificateArn>` (auto-008 §5 cert
delivery source). Created by provider-kubernetes (hub ProviderConfig) or a small
hub Job reading the connection secret.

## Step 5 — Overlay the ephemeral values + let the spoke apps converge

The spoke Applications (`argocd/apps/spoke/*`, PR #145) are inert until the
`platform-spoke` cluster Secret exists. Patch each Application's `helm.valuesObject`
with the live values (cert ARN, external-dns role ARN, `domain`, `AWS_REGION`)
sourced from the XR status / state — via `argocd app set ... --helm-set` or the
cluster-Secret annotation. Then they sync (waves 20 → 30):
ingress-nginx (NLB w/ ACM cert) → external-dns (platform.<domain>) → hello.

## Step 6 — Verify (REQ-PLAT-06)

```sh
# egress sanity first (auto-008 §7):
#   apply tests/e2e/spoke-egress-probe.yaml on the spoke (via a CI kubectl), expect rc=0
host=hello.platform.<domain>
dig +short "$host"                       # ExternalDNS created the A/ALIAS
curl -v "https://$host"                  # 200, valid ACM (publicly-trusted) chain, no manual steps
```
Confirm cert chain is ACM-issued (not self-signed) and the Route53 record + DNS
resolution happened with zero manual steps. That closes REQ-PLAT-02/03/04/06.

---

## If ArgoCD is unreachable (503) when starting

mgmt apply-and-verify gated on ArgoCD HTTPS-200, so 503 is transient
(argocd-server settling after the app-of-apps sync). Re-poll healthz until 200,
then proceed. If persistently down, dispatch `phase=management action=verify`
(re-runs the ArgoCD-200 check + argocd-url) to force a re-check, or inspect via a
CI kubectl (`kubectl -n argocd get pods`). Do NOT apply the XR via sandbox kubectl
(private CA blocked).
