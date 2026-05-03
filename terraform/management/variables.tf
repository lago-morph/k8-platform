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

variable "acme_email" {
  description = "Email address registered with Let's Encrypt for certificate expiry notifications"
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
  default     = "1.29"
}

variable "node_instance_type" {
  description = "EC2 instance type for the management cluster node group"
  type        = string
  default     = "t3.medium"
}

variable "node_desired_size" {
  description = "Desired number of nodes in the management cluster node group"
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum number of nodes in the management cluster node group"
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum number of nodes in the management cluster node group"
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
  description = "Crossplane Helm chart version"
  type        = string
  default     = "1.15.1"
}

variable "eso_version" {
  description = "External Secrets Operator Helm chart version"
  type        = string
  default     = "0.9.13"
}

variable "ingress_nginx_version" {
  description = "ingress-nginx Helm chart version (management cluster only — for ArgoCD UI)"
  type        = string
  default     = "4.10.0"
}

variable "cert_manager_version" {
  description = "cert-manager Helm chart version"
  type        = string
  default     = "1.14.4"
}
