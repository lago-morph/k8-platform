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
    Pluralsight sandbox restriction: use t3.medium or smaller.
    t3.medium (2 vCPU / 4 GiB) is the recommended minimum for running
    ArgoCD + Crossplane + ESO on the same node group.
  EOT
  type        = string
  default     = "t3.medium"
}

variable "node_desired_size" {
  description = "Desired node count. Keep at 2 for management cluster HA; reduce to 1 to stay within sandbox instance limits."
  type        = number
  default     = 2
}

variable "node_min_size" {
  type    = number
  default = 1
}

variable "node_max_size" {
  description = "Max nodes. Pluralsight sandbox caps total EC2 instances across all services — stay conservative."
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
  default     = "2.0.1"
}

variable "crossplane_provider_family_aws_version" {
  description = "Upbound provider-family-aws package version (v1.x for Crossplane v2)"
  type        = string
  default     = "v1.12.0"
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
