# auto-016-001 — Narrow the Crossplane provider role's RDS + EC2 statements

**Status:** Round 2 (Round 1 superseded — text preserved below) · **Owner-decision
territory** (OI-2026-06-08-1 follow-up) · **Run:** auto-016 (unattended) ·
**Rewind:** revert the implementing PR; the live policy reverts to the broad
superset on the next mgmt apply from `main` (safe).

---

## ROUND 2 — revised decision (after wave-1: 3 real reviewers, unanimous)

Wave-1 (IAM-correctness + fail-closed-regulator + tree-fact-checker) **converged
independently** on the same two fail-closed blockers and one lint gap. Round-1's
proposed shape (below) is **superseded**; the corrected shape:

### Blocker findings folded in

- **B1 — `ec2:Vpc` does NOT apply to route-table/association/route actions.**
  `CreateRoute`, `DeleteRoute`, `AssociateRouteTable`, `DisassociateRouteTable`,
  `DeleteRouteTable` take a RouteTableId/SubnetId, not a VpcId — the `ec2:Vpc` key
  is absent from the request context, so a `StringEquals ec2:Vpc` condition
  evaluates to **deny**. Only the actions that carry a VpcId/VPC-bearing resource
  support it: `CreateSubnet`, `DeleteSubnet`, `ModifySubnetAttribute`,
  `CreateRouteTable`, `AuthorizeSecurityGroupIngress`, `RevokeSecurityGroupIngress`.
- **B2 — no `DBSubnetGroup` MR is composed (tree-confirmed); provider likely
  tags-after-create.** `xdatabase.yaml` composes exactly one MR (the Instance). An
  `aws:RequestTag/ManagedBy` condition on `rds:CreateDBInstance` risks a fail-closed
  create if the Upbound provider applies tags in a later reconcile pass (unproven).
  Drop `RequestTag` on create; ARN-type-scope create; `ResourceTag`-condition only
  the mutate/delete/tag set (the Instance IS tagged `ManagedBy: crossplane`).
- **Lint gap — `tests/unit/test_iam_resource_scoping.sh:46-50` currently asserts
  RDS + EC2 (+ EKS + ACM) STAY `"*"`.** Narrowing RDS/EC2 MUST move those two Sids
  from the "must-stay-`*`" group to a "must-be-narrowed" group in the same PR, or
  the lint fails the narrowed policy. EKS + ACM stay `*` (opaque ARNs).

### Round-2 decision: SPLIT into two stacked PRs, conservative shapes

**RDS PR** — `terraform/management/irsa.tf`, replace Sid `RDS` with three Sids:
- `RDSCreate`: `rds:CreateDBInstance`, `rds:CreateDBSubnetGroup` on
  `arn:aws:rds:<region>:<acct>:db:*` + `…:subgrp:*` — **no condition** (avoids the
  tags-on-create unknown; still type-scoped vs `Resource:"*"`).
- `RDSManage`: `ModifyDBInstance`, `DeleteDBInstance`, `RebootDBInstance`,
  `ModifyDBSubnetGroup`, `DeleteDBSubnetGroup`, `AddTagsToResource`,
  `RemoveTagsFromResource` on `db:*`+`subgrp:*` with
  `Condition StringEquals { aws:ResourceTag/ManagedBy = "crossplane" }`.
- `RDSDescribe`: `DescribeDBInstances`, `DescribeDBSubnetGroups`,
  `ListTagsForResource` on `*` (list-shaped; no resource perms).

**EC2 PR** — replace Sid `EC2Networking` with two Sids:
- `EC2VpcScoped`: `CreateSubnet`, `DeleteSubnet`, `ModifySubnetAttribute`,
  `CreateRouteTable`, `AuthorizeSecurityGroupIngress`, `RevokeSecurityGroupIngress`
  on `*` with `Condition StringEquals { ec2:Vpc =
  "arn:aws:ec2:<region>:<acct>:vpc/<base-vpc-id>" }` (base VPC id from
  `data.terraform_remote_state.base.outputs.vpc_id`; add a Terraform
  `precondition`/`validation` so an empty id fails fast instead of denying all).
- `EC2Unconditioned`: `Describe*`, `CreateRoute`, `DeleteRoute`, `DeleteRouteTable`,
  `AssociateRouteTable`, `DisassociateRouteTable`, `CreateTags`, `DeleteTags` on
  `*` (these don't carry `ec2:Vpc`; Describe is permless; CreateTags spans mixed
  resource types). Still narrower in intent; the VPC-bound creates are the
  meaningful blast-radius reduction.

**Proof obligation (in each PR):** apply, then prove on the live CREATE path — the
spoke cluster's EC2 MRs (subnets/route-table/relay-ingress) reconcile green, and the
Keycloak-DB RDS Instance reaches Ready, under the narrowed policy. Name "a second
XDatabase XR with a non-`keycloak-db` name" and "a second spoke" as explicit future
proof obligations (the tag-condition + VPC-condition shapes cover them by
construction, but they aren't exercised this run). Hold both PRs as **sentinel-gated
drafts** until the live CREATE-path proof passes (NOT `simulate-principal-policy`,
§6.39).

---

## ROUND 1 (SUPERSEDED — preserved for traceability)


---

## Question

The Crossplane provider IRSA role (`terraform/management/irsa.tf`) still grants
`Resource = "*"` on two statements:

- **`RDS`** (Sid `RDS`, irsa.tf:124-135) — 12 control-plane actions on `*`.
- **`EC2Networking`** (Sid `EC2Networking`, irsa.tf:47-64) — Describe* + subnet/route/
  SG-ingress mutations on `*`.

auto-015 narrowed IAM-role + OIDC-provider to derived ARNs and proved it on the
spoke CREATE path (ADR-79a955b122). RDS + EC2 were deferred (each gated on the
provision that exercises it). This brief decides **the exact narrowed shape** for
RDS and EC2, to be applied then proven on the live CREATE path (RDS needs the
Keycloak-DB provision; EC2 is exercised by the spoke cluster's subnet/route/SG MRs).

## Established facts (tree-grounded)

- RDS Instance is created by `crossplane/compositions/xdatabase.yaml`. External-name
  = XR name (xdatabase.yaml:127-129) ⇒ `DBInstanceIdentifier = <xr-name>` (today only
  `keycloak-db`). Instance is tagged `ManagedBy: crossplane`, `PlatformAbstraction:
  XDatabase` (xdatabase.yaml:110-112). The Composition also creates a **DB subnet
  group** (`rds:CreateDBSubnetGroup` is in the policy) — its identifier/tagging needs
  confirming in the Composition.
- EC2 mutations come from the platform-cluster Composition (subnets, route tables,
  `kube-relay-ingress` SecurityGroupRule on the shared base VPC). `ec2:Describe*` has
  no resource-level ARN (must stay `*`). The base VPC id is a known data source at
  mgmt-apply time.
- §6.39: `simulate-principal-policy` is unusable on a freshly-modified IRSA role —
  the firing proof is the live CREATE path + a Sid-anchored source lint, NOT the
  simulator.

## Alternatives

**A. RDS: tag-condition on create + ResourceTag on mutate; subnet-group + db ARNs.
EC2: `ec2:Vpc` condition on VPC-scoped mutations.** (Recommended.)
- RDS mutate/create actions keep broad resource ARNs (`db:*`, `subgrp:*` in-account/
  region) but gate **create** on `aws:RequestTag/ManagedBy = crossplane` (+ require
  the tag) and **modify/delete/tag** on `aws:ResourceTag/ManagedBy = crossplane`.
  `Describe*` + `ListTagsForResource` stay `*` (list-shaped, no resource perms).
- EC2 VPC-scoped mutations (CreateSubnet, Create/DeleteRoute(Table), Associate, SG
  ingress) gated on `ec2:Vpc = <base-vpc-arn>`; `Describe*` + `Create/DeleteTags`
  stay `*` (CreateTags has weak resource semantics across mixed resource types).

**B. RDS: exact `db:<xr-name>` ARN (no tag condition). EC2: same as A.**
- Pins RDS to `db:keycloak-db` literally. Tightest, but breaks the moment a second
  XDatabase XR with a different name is provisioned, and couples the IAM policy to a
  workload name (a layering smell). Rejected unless the team wants single-DB lock-in.

**C. Leave RDS + EC2 at `*`; narrow nothing.**
- Zero risk of a fail-closed regression, but leaves the OI-1 follow-up open and the
  blast radius wide. Rejected — the whole point of OI-1 is to close this.

## Decision (Round 1)

**Alternative A.** Tag-condition is the right tool for RDS because create-time
identifiers are deterministic but workload-named (not `k8-platform-*` prefixed), so a
prefix ARN buys nothing a `ManagedBy` tag-condition doesn't, and the tag survives a
rename. `ec2:Vpc` is the canonical EC2 scope key and the base VPC is known at apply.

### Exact shape (subject to review)

RDS split into two statements:
- `RDSCreate`: `rds:CreateDBInstance`, `rds:CreateDBSubnetGroup` on
  `arn:aws:rds:<region>:<acct>:{db,subgrp}:*` with
  `Condition StringEquals { aws:RequestTag/ManagedBy = "crossplane" }`.
- `RDSManage`: modify/delete/reboot/tag on `{db,subgrp}:*` with
  `Condition StringEquals { aws:ResourceTag/ManagedBy = "crossplane" }`.
- `RDSDescribe`: `rds:DescribeDBInstances`, `rds:DescribeDBSubnetGroups`,
  `rds:ListTagsForResource` on `*` (unconditioned — list-shaped).

EC2 split:
- `EC2VpcScoped`: subnet/route/SG-ingress mutations on `*` with
  `Condition StringEquals { ec2:Vpc = "arn:aws:ec2:<region>:<acct>:vpc/<base-vpc-id>" }`.
- `EC2Describe`: `ec2:Describe*`, `ec2:CreateTags`, `ec2:DeleteTags` on `*`
  unconditioned (Describe is permless; CreateTags spans creation calls where the
  `ec2:Vpc` key is not always present).

## Downstream impact / risks

- **Fail-closed risk:** if the AWS provider issues an RDS create WITHOUT the
  `ManagedBy` tag in the same request (tags applied in a later reconcile), the
  `RequestTag` condition denies create. MUST confirm the provider tags-on-create for
  the Instance AND the subnet group (the subnet group's tags are not visible in the
  Read excerpt — needs checking). If the provider tags-after-create, fall back to
  ARN-scoping create and ResourceTag-condition only the mutate set.
- **EC2 `ec2:Vpc` gotchas:** `CreateSubnet`/`CreateRouteTable` accept the `ec2:Vpc`
  key (they reference a VpcId); but `CreateRoute`/route-table associations reference
  the route table, not the VPC directly — verify each action supports `ec2:Vpc` or
  the rule denies a real MR. SG-ingress (`Authorize/Revoke`) references the SG; it
  supports `ec2:Vpc`.
- **Proof obligation (§6.35 + §6.39):** apply, then prove on the live CREATE path —
  the spoke cluster's EC2 MRs reconcile green (subnets/routes/relay-ingress) and the
  Keycloak-DB RDS Instance + subnet group reach Ready under the narrowed policy. Hold
  the PR as a **sentinel-gated draft** until both are validated live. NOT the
  simulator.

## Round-1 if-user-overrides rewind point

Revert the implementing commit. The next `terraform apply` from `main` reapplies the
broad superset (the live policy is only ever narrower than `main` until merge), so an
override is always safe and never strands the spoke.
