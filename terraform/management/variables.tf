variable "aws_region" {
  description = "AWS region (must match terraform/base)"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Short environment label applied to all resource tags"
  type        = string
  default     = "dev"
}

variable "domain" {
  description = "Root domain name (must match terraform/base, e.g. example.com)"
  type        = string
}

variable "tf_state_bucket" {
  description = "S3 bucket that holds both the base and management Terraform state"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name for the management cluster"
  type        = string
  default     = "k8-platform-mgmt"
}

variable "cluster_version" {
  description = "Kubernetes version for the management cluster"
  type        = string
  default     = "1.35"
}

variable "node_instance_type" {
  description = <<-EOT
    EC2 instance type for management cluster nodes.
    Account constraint: t3.medium or smaller (see ai/testing-guidelines.md §1).
    t3.medium (2 vCPU / 4 GiB) is the recommended minimum for running
    ArgoCD + Crossplane + ESO on the same node group.
  EOT
  type        = string
  default     = "t3.medium"
}

variable "node_desired_size" {
  description = "Desired node count. 3 nodes for the management stack (Crossplane + 6 providers + functions + ESO + Kyverno + ArgoCD + ingress-nginx + external-dns). Stay within the 9-instance EC2 quota."
  type        = number
  default     = 3
}

variable "node_min_size" {
  type    = number
  default = 1
}

variable "node_max_size" {
  description = "Max nodes. The account caps total EC2 instances across all services — stay conservative."
  type        = number
  default     = 3
}

variable "availability_zones" {
  description = "AZs to place management cluster subnets in (must be a subset of base AZs)"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "argocd_version" {
  description = "ArgoCD Helm chart version"
  type        = string
  default     = "6.7.3"
}

variable "crossplane_version" {
  description = "Crossplane Helm chart version (v2.x)"
  type        = string
  default     = "2.3.0"
}

variable "crossplane_provider_family_aws_version" {
  description = "Upbound provider-family-aws package version (v2.x for Crossplane v2)"
  type        = string
  default     = "v2.5.0"
}

variable "crossplane_provider_aws_secretsmanager_version" {
  description = <<-EOT
    Upbound provider-aws-secretsmanager package version. The family-aws
    package above is a meta-package; each AWS service has its own child
    provider. PlatformSecret claims need the secretsmanager child to
    reconcile the ASM Secret managed resource.
  EOT
  type        = string
  default     = "v2.5.0"
}

variable "crossplane_function_patch_and_transform_version" {
  description = <<-EOT
    crossplane-contrib/function-patch-and-transform package version.
    Required by every v2 Pipeline Composition that uses the legacy
    resources/patches input shape. Crossplane v2 removed
    `spec.resources` from the v1 Composition schema, so every
    Composition the platform ships goes through this function.
  EOT
  type        = string
  default     = "v0.10.6"
}

variable "crossplane_function_environment_configs_version" {
  description = <<-EOT
    crossplane-contrib/function-environment-configs package version.
    Merges named EnvironmentConfig data into the pipeline environment so
    the platform-cluster Composition can read account-ephemeral infra
    values (private subnet IDs, route53 zone id, root domain) from the
    cluster-network EnvironmentConfig that this module materializes from
    the base Terraform output. Must match
    tests/chainsaw/versions.env (FUNCTION_ENVIRONMENT_CONFIGS_VERSION).
  EOT
  type        = string
  default     = "v0.3.0"
}

variable "crossplane_provider_aws_eks_version" {
  description = <<-EOT
    Upbound provider-aws-eks package version. Child of provider-family-aws
    needed by the XPlatformCluster Composition to reconcile the EKS
    Cluster and NodeGroup managed resources. Pin to the family version.
  EOT
  type        = string
  default     = "v2.5.0"
}

variable "crossplane_provider_aws_iam_version" {
  description = <<-EOT
    Upbound provider-aws-iam package version. Child of provider-family-aws
    needed by the XPlatformCluster Composition to reconcile the cluster /
    node-group IAM Roles and RolePolicyAttachments. Pin to the family.
  EOT
  type        = string
  default     = "v2.5.0"
}

variable "crossplane_provider_aws_acm_version" {
  description = <<-EOT
    Upbound provider-aws-acm package version. Child of provider-family-aws
    needed by the XPlatformCluster Composition to provision the wildcard
    ACM Certificate + CertificateValidation for the cluster's TLS
    (docs/decisions/0003). Pin to the family version.
  EOT
  type        = string
  default     = "v2.5.0"
}

variable "crossplane_provider_aws_route53_version" {
  description = <<-EOT
    Upbound provider-aws-route53 package version. Child of
    provider-family-aws needed by the XPlatformCluster Composition to
    create the ACM DNS-validation Record (docs/decisions/0003). Pin to
    the family version.
  EOT
  type        = string
  default     = "v2.5.0"
}

variable "eso_version" {
  description = "External Secrets Operator Helm chart version"
  type        = string
  default     = "0.9.13"
}

variable "ingress_nginx_version" {
  description = "ingress-nginx Helm chart version"
  type        = string
  default     = "4.10.0"
}

variable "external_dns_version" {
  description = "ExternalDNS Helm chart version (kubernetes-sigs/external-dns)"
  type        = string
  default     = "1.15.0"
}

variable "kyverno_version" {
  description = "Kyverno Helm chart version (audit-mode policy engine)"
  type        = string
  default     = "3.2.6"
}
