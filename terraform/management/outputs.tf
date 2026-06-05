output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded CA certificate for the EKS cluster"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC provider — used by downstream IRSA role modules"
  value       = module.eks.oidc_provider_arn
}

output "irsa_crossplane_role_arn" {
  description = "IAM role ARN for Crossplane AWS provider"
  value       = module.irsa_crossplane.iam_role_arn
}

output "irsa_eso_role_arn" {
  description = "IAM role ARN for External Secrets Operator"
  value       = module.irsa_eso.iam_role_arn
}

output "argocd_url" {
  description = "ArgoCD UI URL (valid once the ACM cert is bound to the ingress NLB)"
  value       = "https://argocd.management.${var.domain}"
}
