# IRSA roles for components running on the management cluster.
# Each role is scoped to a single service account in a single namespace
# with the minimum permissions needed — see REQ-MGMT-05.

locals {
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider     = module.eks.cluster_oidc_issuer_url
  account_id        = data.aws_caller_identity.current.account_id
  region            = var.aws_region
  zone_id           = try(data.terraform_remote_state.base.outputs.route53_zone_id, "")
}

# ---- ArgoCD ----

module "irsa_argocd" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${var.cluster_name}-argocd"

  oidc_providers = {
    main = {
      provider_arn               = local.oidc_provider_arn
      namespace_service_accounts = ["argocd:argocd-server", "argocd:argocd-application-controller"]
    }
  }

  role_policy_arns = {}
}

# ---- Crossplane AWS Provider ----

resource "aws_iam_policy" "crossplane_aws" {
  name        = "${var.cluster_name}-crossplane-aws"
  description = "Permissions for Crossplane AWS provider on the management cluster"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EKS"
        Effect   = "Allow"
        Action   = ["eks:*"]
        Resource = "*"
      },
      # EC2 networking — the platform-cluster Composition creates subnets, route
      # tables, and the kube-relay-ingress SecurityGroupRule in the shared base
      # VPC. auto-016-001 (OI-2026-06-08-1 follow-up) splits the former single
      # Resource:"*" `EC2Networking` Sid into a VPC-conditioned set and an
      # unconditioned set. Two adversarial rounds (6 reviewers) established that
      # the ec2:Vpc condition key is ONLY present in the auth context for actions
      # whose request carries a VPC-bearing resource — applying it to the others
      # (route/association/route-table-delete, subnet delete/modify) would deny a
      # real MR (absent-key + StringEquals = deny). Do NOT rename these Sids
      # without updating tests/unit/test_iam_resource_scoping.sh.
      {
        # EC2VpcScoped — only the actions confirmed to carry ec2:Vpc:
        # CreateSubnet + CreateRouteTable (request carries VpcId),
        # DeleteSecurityGroup (the SG resolves to its VPC) and
        # Authorize/RevokeSecurityGroupIngress (the SG resolves to its VPC).
        # Pinned to the base VPC so Crossplane cannot create networking in any
        # other VPC. (DeleteSubnet/ModifySubnetAttribute do NOT carry ec2:Vpc —
        # they live in EC2Unconditioned below. CreateSecurityGroup gets its
        # own Sid below: it authorizes against the security-group AND the
        # vpc resource, and the VPC resource type does NOT carry the
        # ec2:Vpc condition key — conditioning it here is absent-key +
        # StringEquals = deny. Proven live 2026-06-11: UnauthorizedOperation
        # on vpc/<base-vpc> for the XDatabase rds SG under this Sid.)
        Sid    = "EC2VpcScoped"
        Effect = "Allow"
        Action = [
          "ec2:CreateSubnet", "ec2:CreateRouteTable",
          "ec2:DeleteSecurityGroup",
          "ec2:AuthorizeSecurityGroupIngress", "ec2:RevokeSecurityGroupIngress",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "ec2:Vpc" = "arn:aws:ec2:${local.region}:${local.account_id}:vpc/${local.base_vpc_id}"
          }
        }
      },
      {
        # CreateSecurityGroup authorizes against TWO resources: the
        # to-be-created security-group AND the target vpc. Scoping rides
        # the resource-pinned VPC ARN (creating in any other VPC fails on
        # the vpc resource) — no condition, because the vpc resource type
        # lacks the ec2:Vpc auth-context key.
        Sid    = "EC2CreateSecurityGroupInBaseVpc"
        Effect = "Allow"
        Action = ["ec2:CreateSecurityGroup"]
        Resource = [
          "arn:aws:ec2:${local.region}:${local.account_id}:security-group/*",
          "arn:aws:ec2:${local.region}:${local.account_id}:vpc/${local.base_vpc_id}",
        ]
      },
      {
        # EC2Unconditioned — Describe* is list-shaped (no resource-level ARN);
        # the route/association/route-table-delete and subnet delete/modify
        # actions do NOT carry the ec2:Vpc condition key (their request targets a
        # route-table/subnet id, not a VpcId), and CreateTags/DeleteTags span
        # mixed resource types where the VPC is not reliably in context. These
        # stay Resource:"*" by necessity — an INTENTIONAL wildcard (lint
        # allow-lists this Sid in the must-stay-"*" group). The meaningful
        # blast-radius reduction is the VPC-bound creates above.
        Sid    = "EC2Unconditioned"
        Effect = "Allow"
        Action = [
          "ec2:Describe*",
          "ec2:DeleteSubnet", "ec2:ModifySubnetAttribute",
          "ec2:DeleteRouteTable",
          "ec2:CreateRoute", "ec2:DeleteRoute",
          "ec2:AssociateRouteTable", "ec2:DisassociateRouteTable",
          "ec2:CreateTags", "ec2:DeleteTags",
        ]
        Resource = "*"
      },
      {
        # auto-015-001 (OI-2026-06-08-1): IAM role actions scoped to the DERIVED
        # prefix instead of Resource:"*". Every IAM role Crossplane creates or
        # passes is k8-platform-* — k8-platform-cluster-<name>,
        # k8-platform-nodegroup-<name>, k8-platform-<cluster>-external-dns
        # (verified against crossplane/compositions/*.yaml). The mgmt hub roles
        # are Terraform-created (operator creds), so ONLY the spoke's
        # Crossplane-created roles exercise this — validated on the spoke
        # XSpokeAccess CREATE path before this narrowing is called done (§6.35).
        # The paired firing proof is the live simulate-principal-policy deny
        # check (tests/live/checks/negative/iam-resource-scope-denied.sh); the
        # source regression guard is tests/unit/test_iam_resource_scoping.sh.
        Sid    = "IAMRoles"
        Effect = "Allow"
        Action = [
          "iam:CreateRole", "iam:DeleteRole",
          "iam:AttachRolePolicy", "iam:DetachRolePolicy",
          "iam:PutRolePolicy", "iam:DeleteRolePolicy",
          # The XSpokeAccess external-dns Role's IRSA trust policy is rebuilt
          # from the (late-bound) spoke OIDC issuer, so Crossplane must be able
          # to UPDATE the assume-role policy after create; and its inline
          # RolePolicy is observed via GetRolePolicy before each reconcile.
          # Both fail closed without these (auto-012): observed live as
          # "AccessDenied iam:UpdateAssumeRolePolicy" (Role Synced=False) and
          # "AccessDenied iam:GetRolePolicy" (RolePolicy never created).
          "iam:UpdateAssumeRolePolicy", "iam:GetRolePolicy",
          "iam:GetRole", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
          "iam:TagRole", "iam:UntagRole",
          # PassRole targets are the cluster-role / node-role, both k8-platform-*.
          "iam:PassRole",
        ]
        Resource = "arn:aws:iam::${local.account_id}:role/k8-platform-*"
      },
      {
        # auto-015-001: OIDC-provider actions scoped to oidc-provider/* (one IRSA
        # OIDC provider per spoke). The XSpokeAccess Composition tags it
        # (ManagedBy / PlatformAbstraction / ClusterName); EKS OIDC-provider
        # create-with-tags fails closed without Tag* (auto-012): observed
        # "AccessDenied ... iam:TagOpenIDConnectProvider" at spoke-access sync.
        # Untag pairs with it for managementPolicies Update/Delete.
        # CreateOpenIDConnectProvider evaluates the to-be-created provider ARN
        # against oidc-provider/* (resource-level perms apply at create time).
        Sid    = "IAMOIDCProviders"
        Effect = "Allow"
        Action = [
          "iam:CreateOpenIDConnectProvider", "iam:DeleteOpenIDConnectProvider",
          "iam:GetOpenIDConnectProvider",
          "iam:TagOpenIDConnectProvider", "iam:UntagOpenIDConnectProvider",
        ]
        Resource = "arn:aws:iam::${local.account_id}:oidc-provider/*"
      },
      # auto-016 — EKS service-linked roles. When Crossplane creates the
      # SPOKE EKS NodeGroup, EKS's CreateNodegroup validates (and, first time,
      # creates) the service-linked role AWSServiceRoleForAmazonEKSNodegroup,
      # which requires iam:GetRole on that SLR. The auto-015 IAMRoles Sid
      # narrowed iam:GetRole to role/k8-platform-*, which does NOT cover the
      # SLR path role/aws-service-role/eks-nodegroup.amazonaws.com/* — so a
      # fresh-account spoke bring-up under the narrowed policy fails closed:
      #   InvalidRequestException: Failed to validate if SLR:
      #   AWSServiceRoleForAmazonEKSNodegroup already exists due to missing
      #   permissions for 'iam:GetRole'
      # (found live on the spoke nodegroup CREATE path, auto-016 — NOT a lint;
      # auto-015 only validated the spoke-access path, where the nodegroup SLR
      # is not exercised). Scope GetRole + CreateServiceLinkedRole to the EKS
      # service-linked-role path only. Keep this Sid name in sync with
      # tests/unit/test_iam_resource_scoping.sh.
      {
        Sid    = "EKSServiceLinkedRoles"
        Effect = "Allow"
        Action = [
          "iam:GetRole",
          "iam:CreateServiceLinkedRole",
        ]
        Resource = "arn:aws:iam::${local.account_id}:role/aws-service-role/eks*.amazonaws.com/*"
      },
      # RDS — the XDatabase Composition (phase 5) provisions an RDS Postgres
      # Instance for Keycloak. auto-016-001 (OI-2026-06-08-1 follow-up) narrows
      # the former single Resource:"*" `RDS` Sid into three Sids. The narrowing
      # was decided across two adversarial review rounds (6 real reviewers) —
      # planning/test-overhaul/decisions/auto-016-001-*. Do NOT rename these
      # Sids without updating tests/unit/test_iam_resource_scoping.sh (the
      # Sid-anchored source lint keys off these exact names).
      {
        # RDSWrite — create + tag, plus the (today-unexercised) subnet-group
        # mutations. UNCONDITIONED on purpose: the Upbound provider may apply
        # the ManagedBy tag in the CreateDBInstance request OR a later
        # AddTagsToResource pass; a create-time aws:RequestTag/ResourceTag
        # condition would deny the very call that establishes the tag
        # (chicken-and-egg) — a fail-closed trap the reviewers flagged. We scope
        # by ARN *type* instead (db:* / subgrp:* in this account+region), which
        # is the meaningful narrowing vs Resource:"*". The XDatabase Composition
        # composes no DBSubnetGroup MR, so the subnet-group mutates are never
        # exercised today (left here for a future explicit subnet-group MR).
        Sid    = "RDSWrite"
        Effect = "Allow"
        Action = [
          "rds:CreateDBInstance",
          "rds:AddTagsToResource", "rds:RemoveTagsFromResource",
          "rds:CreateDBSubnetGroup", "rds:ModifyDBSubnetGroup",
          "rds:DeleteDBSubnetGroup",
        ]
        Resource = [
          "arn:aws:rds:${local.region}:${local.account_id}:db:*",
          "arn:aws:rds:${local.region}:${local.account_id}:subgrp:*",
        ]
      },
      {
        # RDSModifyInstance — the destructive post-create instance ops, gated on
        # the RDS-native tag key rds:db-tag/ManagedBy=crossplane (NOT the global
        # aws:ResourceTag, which the RDS SAR does not list for these actions —
        # an absent key with StringEquals = deny). These only fire on an
        # already-created, already-tagged Instance, so the condition is always
        # satisfied for our MRs and denies anyone else's untagged DB instance.
        Sid    = "RDSModifyInstance"
        Effect = "Allow"
        Action = [
          "rds:ModifyDBInstance", "rds:DeleteDBInstance", "rds:RebootDBInstance",
        ]
        Resource  = "arn:aws:rds:${local.region}:${local.account_id}:db:*"
        Condition = { StringEquals = { "rds:db-tag/ManagedBy" = "crossplane" } }
      },
      {
        # ModifyDBInstance with a DBSubnetGroupName parameter authorizes
        # against the SUBNET-GROUP resource in addition to the db instance
        # (multi-resource auth — same class as ec2:CreateSecurityGroup's
        # security-group+vpc pair). The tag-conditioned db:* Sid above
        # cannot cover it: subnet groups carry no rds:db-tag. Proven live
        # 2026-06-11: AccessDenied rds:ModifyDBInstance on
        # subgrp:keycloak-db-rds moving the XDatabase instance into the
        # base VPC (OI-2026-06-11-1). The db-side tag condition above still
        # gates WHICH instances are modifiable.
        Sid      = "RDSModifyInstanceSubnetGroup"
        Effect   = "Allow"
        Action   = ["rds:ModifyDBInstance"]
        Resource = "arn:aws:rds:${local.region}:${local.account_id}:subgrp:*"
      },
      {
        # RDSDescribe — list/observe operations are list-shaped (no resource-level
        # ARN), so they stay Resource:"*". This is an INTENTIONAL wildcard, not a
        # lazy one (the lint allow-lists this Sid in the must-stay-"*" group).
        Sid    = "RDSDescribe"
        Effect = "Allow"
        Action = [
          "rds:DescribeDBInstances", "rds:DescribeDBSubnetGroups",
          "rds:ListTagsForResource",
        ]
        Resource = "*"
      },
      {
        Sid    = "SecretsManager"
        Effect = "Allow"
        Action = [
          "secretsmanager:CreateSecret", "secretsmanager:DeleteSecret",
          "secretsmanager:PutSecretValue", "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret", "secretsmanager:TagResource",
          "secretsmanager:UntagResource",
          # upjet's Secret READ path calls GetResourcePolicy on every observe;
          # without it the MR creates fine then sits Synced=False forever
          # (clean build #4, fourth live defect - AccessDenied on observe).
          "secretsmanager:GetResourcePolicy",
          # SecretVersion MR lifecycle (the platform-secret material chain):
          # deleting/retiring a version moves its staging labels.
          "secretsmanager:UpdateSecretVersionStage",
        ]
        Resource = "arn:aws:secretsmanager:${local.region}:${local.account_id}:secret:k8-platform/*"
      },
      {
        # ACM — the XPlatformCluster Composition provisions and
        # DNS-validates a per-cluster wildcard certificate
        # (docs/decisions/0003). ACM certificate ARNs are not known ahead
        # of issuance, so the management actions are account-wide; they are
        # cert-scoped operations, not data access.
        Sid    = "ACM"
        Effect = "Allow"
        Action = [
          "acm:RequestCertificate", "acm:DeleteCertificate",
          "acm:DescribeCertificate", "acm:GetCertificate",
          "acm:ListCertificates", "acm:ListTagsForCertificate",
          "acm:AddTagsToCertificate", "acm:RemoveTagsFromCertificate",
          "acm:RenewCertificate",
        ]
        Resource = "*"
      },
      {
        # Route53 — write the ACM DNS-validation CNAME into the cluster's
        # hosted zone and poll the change. Record-write is scoped to the
        # base hosted zone; the list/change operations are global by API
        # shape. Mirrors the ExternalDNS route53_editor policy below.
        Sid    = "Route53Validation"
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets",
          "route53:ListResourceRecordSets",
          "route53:GetHostedZone",
        ]
        Resource = "arn:aws:route53:::hostedzone/${local.zone_id}"
      },
      {
        Sid    = "Route53Read"
        Effect = "Allow"
        Action = [
          "route53:GetChange",
          "route53:ListHostedZones",
          "route53:ListHostedZonesByName",
          "route53:ListTagsForResource",
        ]
        Resource = "*"
      },
    ]
  })

  # auto-016-001: the EC2VpcScoped statement embeds the base VPC ARN in its
  # ec2:Vpc condition. If base hasn't been applied (vpc_id == ""), the condition
  # value becomes ".../vpc/" and would DENY every VPC-scoped EC2 action — a
  # silent fail-closed. Fail fast at plan time instead. (Management always
  # applies after base in a normal bring-up, so this only fires on misuse.)
  lifecycle {
    precondition {
      condition     = local.base_vpc_id != ""
      error_message = "base VPC id is empty — apply terraform/base first so the EC2VpcScoped ec2:Vpc condition resolves to a real VPC ARN."
    }
  }
}

module "irsa_crossplane" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${var.cluster_name}-crossplane"

  oidc_providers = {
    main = {
      provider_arn               = local.oidc_provider_arn
      namespace_service_accounts = ["crossplane-system:upbound-provider-family-aws"]
    }
  }

  role_policy_arns = {
    crossplane = aws_iam_policy.crossplane_aws.arn
  }
}

# ---- External Secrets Operator ----

resource "aws_iam_policy" "eso" {
  name        = "${var.cluster_name}-eso"
  description = "ESO access to Secrets Manager for the management cluster (read + PushSecret write on the platform path)"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ESORead"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecretVersionIds",
        ]
        Resource = "arn:aws:secretsmanager:${local.region}:${local.account_id}:secret:k8-platform/*"
      },
      {
        # PushSecret (hub → ASM) for cross-cluster secret movement
        # (OI-2026-06-07-5: the keycloak-db connection secret travels hub
        # PushSecret → ASM → spoke ExternalSecret, ADR-0005). Write stays
        # scoped to the same k8-platform/* path; spokes get read-only
        # (XSpokeAccess eso-policy). No DeleteSecret: PushSecret
        # deletionPolicy stays None — orphaned pushes are reaped by account
        # rotation, never by ESO.
        Sid    = "ESOPushSecretWrite"
        Effect = "Allow"
        Action = [
          "secretsmanager:CreateSecret",
          "secretsmanager:PutSecretValue",
          "secretsmanager:TagResource",
        ]
        Resource = "arn:aws:secretsmanager:${local.region}:${local.account_id}:secret:k8-platform/*"
      },
    ]
  })
}

module "irsa_eso" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${var.cluster_name}-eso"

  oidc_providers = {
    main = {
      provider_arn               = local.oidc_provider_arn
      namespace_service_accounts = ["external-secrets:external-secrets"]
    }
  }

  role_policy_arns = {
    eso = aws_iam_policy.eso.arn
  }
}

# ---- ExternalDNS ----
# Route53 write access scoped to the hosted zone for this cluster's subdomain.
# cert-manager is not installed on the management cluster (ACM handles TLS),
# so ExternalDNS gets its own Route53 policy rather than sharing one.

resource "aws_iam_policy" "route53_editor" {
  name        = "${var.cluster_name}-route53-editor"
  description = "Route53 record management for ExternalDNS on the management cluster"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["route53:GetChange"]
        Resource = "arn:aws:route53:::change/*"
      },
      {
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets",
          "route53:ListResourceRecordSets",
        ]
        Resource = "arn:aws:route53:::hostedzone/${local.zone_id}"
      },
      {
        Effect = "Allow"
        Action = [
          "route53:ListHostedZones",
          "route53:ListHostedZonesByName",
          "route53:ListTagsForResource",
        ]
        Resource = "*"
      },
    ]
  })
}

module "irsa_external_dns" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${var.cluster_name}-external-dns"

  oidc_providers = {
    main = {
      provider_arn               = local.oidc_provider_arn
      namespace_service_accounts = ["external-dns:external-dns"]
    }
  }

  role_policy_arns = {
    route53 = aws_iam_policy.route53_editor.arn
  }
}
