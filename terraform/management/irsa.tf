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
        Sid    = "EKS"
        Effect = "Allow"
        Action = ["eks:*"]
        Resource = "*"
      },
      {
        Sid    = "EC2Networking"
        Effect = "Allow"
        Action = [
          "ec2:Describe*",
          "ec2:CreateSubnet", "ec2:DeleteSubnet", "ec2:ModifySubnetAttribute",
          "ec2:CreateRouteTable", "ec2:DeleteRouteTable",
          "ec2:CreateRoute", "ec2:DeleteRoute",
          "ec2:AssociateRouteTable", "ec2:DisassociateRouteTable",
          "ec2:CreateTags", "ec2:DeleteTags",
        ]
        Resource = "*"
      },
      {
        Sid    = "IAM"
        Effect = "Allow"
        Action = [
          "iam:CreateRole", "iam:DeleteRole",
          "iam:AttachRolePolicy", "iam:DetachRolePolicy",
          "iam:PutRolePolicy", "iam:DeleteRolePolicy",
          "iam:GetRole", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
          "iam:CreateOpenIDConnectProvider", "iam:DeleteOpenIDConnectProvider",
          "iam:GetOpenIDConnectProvider",
          "iam:TagRole", "iam:UntagRole",
          "iam:PassRole",
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
        ]
        Resource = "arn:aws:secretsmanager:${local.region}:${local.account_id}:secret:k8-platform/*"
      },
    ]
  })
}

module "irsa_crossplane" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${var.cluster_name}-crossplane"

  oidc_providers = {
    main = {
      provider_arn               = local.oidc_provider_arn
      namespace_service_accounts = ["crossplane-system:crossplane", "crossplane-system:provider-aws-*"]
    }
  }

  role_policy_arns = {
    crossplane = aws_iam_policy.crossplane_aws.arn
  }
}

# ---- External Secrets Operator ----

resource "aws_iam_policy" "eso" {
  name        = "${var.cluster_name}-eso"
  description = "ESO read-only access to Secrets Manager for the management cluster"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecretVersionIds",
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
        Effect   = "Allow"
        Action   = ["route53:ListHostedZonesByName"]
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
