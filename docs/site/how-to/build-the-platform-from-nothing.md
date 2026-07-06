---
status: contract
---

# Build the platform from nothing

Take a fresh AWS account and the platform repository to a running,
verified platform. The owner is a user, and this is the platform's
most fundamental user-facing operation: "working" is a property of the
repository, and this page is the procedure that proves it — no AI
tooling, no CI internals, just an operator with credentials and a
checkout.

!!! info "Why this page is `contract`, and what flips it"
    The platform rebuilds itself from this repository routinely — but
    through its CI apparatus, which auto-wires credentials and state.
    The **human-executed** path below is assembled from the committed
    sources (each step cites them) and has not yet been run end-to-end
    by a person. That is a registered platform gap; the run that
    executes this page as written on a fresh account is the evidence
    that flips it `stable`. Where the human path diverges from what
    the machinery does, the step says so.

## Before you start

- An AWS account with administrator-grade credentials in your
  environment, in a supported region (`us-east-1` by default).
- A **domain with a Route53 hosted zone**. The platform discovers the
  zone; it does not create your domain. (On sandbox accounts with a
  pre-created zone, you will supply its zone ID below.)
- An **S3 bucket and DynamoDB lock table for Terraform state**, which
  you create or choose — state lives outside the platform by design so
  the management layer can always be rebuilt or recovered.
- CLI tools: `terraform` (≥ 1.6), `kubectl`, `helm`, `aws`, `argocd`,
  `git`, `curl`.
- A clone of the platform repository, on `main`.

## 1. Base environment (`terraform/base`)

Networking, DNS wiring, and the identity substrate.

```bash
cd terraform/base
cp terraform.tfvars.example terraform.tfvars
# edit: domain, aws_region, availability_zones,
#       route53_zone_id (sandbox accounts), cognito test user
terraform init \
  -backend-config="bucket=<your-state-bucket>" \
  -backend-config="key=base/terraform.tfstate" \
  -backend-config="region=<region>" \
  -backend-config="dynamodb_table=<your-lock-table>"
terraform plan
terraform apply
```

Never commit `terraform.tfvars` — every account-specific value stays
out of Git.

## 2. Management cluster (`terraform/management`)

The hub: EKS plus the GitOps controller and the infrastructure engine,
and the **last step you perform imperatively**.

```bash
cd terraform/management
cp terraform.tfvars.example terraform.tfvars
# edit: domain (must match base), cluster sizing,
#       tf_state_bucket; leave the pinned chart versions alone
terraform init \
  -backend-config="bucket=<your-state-bucket>" \
  -backend-config="key=management/terraform.tfstate" \
  -backend-config="region=<region>" \
  -backend-config="dynamodb_table=<your-lock-table>"
terraform plan
terraform apply
```

This installs Argo CD, Crossplane, and the secrets operator on the new
cluster and applies the single bootstrap Application. From here on,
**everything is GitOps**: the bootstrap app syncs the repository's
`argocd/` tree — projects, composite definitions, compositions, and
every child Application — continuously from `main`.

Get credentials and watch it converge:

```bash
aws eks update-kubeconfig --name k8-platform-mgmt --region <region>
kubectl get applications -n argocd        # children appear and converge
```

The Argo CD UI comes up at `https://argocd.management.<domain>`
(admin credentials are exposed as Terraform outputs — read them with
`terraform output`, never from cluster secrets).

## 3. Pull the two deliberate gates

Cluster creation is intentionally **not** automatic: two Applications
are committed without automated sync, so bringing real infrastructure
into existence is an explicit operator act.

```bash
# 1. Create the platform services cluster (expect ~15-20 minutes to Ready):
argocd app sync platform-cluster-claim
kubectl wait --for=condition=Ready --timeout=1500s \
  xplatformclusters -A --all

# 2. Register the new spoke with the hub:
argocd app sync spoke-access
```

Once the spoke registers, the cluster-fact-driven ApplicationSets fan
the add-on stack out to it automatically — ingress, DNS, secrets,
SSO components, the demo app — in dependency order. No further
commands.

## 4. Verify you are done

The platform's own definition of done, as observables:

```bash
# The behavioral gate — a real hostname, a valid public certificate:
curl -sSf https://hello.platform.<domain>

# The delivery surface — everything Synced/Healthy:
kubectl get applications -n argocd
```

Check the full sweep against
[What a finished platform contains](../reference/finished-platform.md)
— including the items that are expectedly *not* green today. Anything
absent from that inventory, or off-state without a listed reason, is a
defect to file.

## Known divergences from the machinery's path

Stated so you are never surprised mid-build:

- The platform's CI derives its state-backend names and credentials
  automatically; you supplied yours by hand above. The Terraform
  *content* is identical.
- The two manual syncs in step 3 are the same gates the machinery
  pulls — they are the product behaving as designed, not a workaround.
- Two components are expected non-green on a fresh build (observability
  storage, the second workload cluster) — the
  [inventory page](../reference/finished-platform.md) lists them with
  reasons.
