output "vpc_id" {
  description = "ID of the platform VPC"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "CIDR block of the platform VPC"
  value       = aws_vpc.main.cidr_block
}

output "nat_gateway_ids" {
  description = "IDs of the NAT gateways, ordered to match availability_zones"
  value       = aws_nat_gateway.main[*].id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets (one per AZ)"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs of the shared private subnets (one per AZ); each cluster adds its own in terraform/management/"
  value       = aws_subnet.private[*].id
}

output "route53_zone_id" {
  description = "Route53 hosted zone ID for the root domain"
  value       = local.zone_id
}

output "route53_zone_name_servers" {
  description = "Name servers to delegate to (empty when using a pre-existing zone)"
  value       = local.zone_name_servers
}

output "acm_certificate_arn" {
  description = "ARN of the validated wildcard ACM certificate (*.domain + domain)"
  value       = aws_acm_certificate_validation.wildcard.certificate_arn
}

output "cognito_user_pool_id" {
  description = "Cognito user pool ID"
  value       = aws_cognito_user_pool.main.id
}

output "cognito_user_pool_arn" {
  description = "Cognito user pool ARN"
  value       = aws_cognito_user_pool.main.arn
}

output "cognito_client_id" {
  description = "Cognito app client ID for Keycloak"
  value       = aws_cognito_user_pool_client.keycloak.id
}

output "cognito_client_secret" {
  description = "Cognito app client secret for Keycloak (sensitive)"
  value       = aws_cognito_user_pool_client.keycloak.client_secret
  sensitive   = true
}

output "cognito_issuer_url" {
  description = "OIDC issuer URL for the Cognito user pool"
  value       = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.main.id}"
}

output "cognito_jwks_uri" {
  description = "JWKS endpoint — used to verify Cognito-issued tokens"
  value       = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.main.id}/.well-known/jwks.json"
}

output "cognito_hosted_ui_domain" {
  description = "Cognito hosted-UI domain prefix (full host: <prefix>.auth.<region>.amazoncognito.com)"
  value       = aws_cognito_user_pool_domain.main.domain
}

output "cognito_idp_secret_name" {
  description = "ASM name of the Keycloak-broker federation inputs (endpoints + confidential client)"
  value       = aws_secretsmanager_secret.cognito_idp.name
}
