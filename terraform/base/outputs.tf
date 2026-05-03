output "vpc_id" {
  description = "ID of the platform VPC"
  value       = aws_vpc.main.id
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
  value       = aws_route53_zone.root.zone_id
}

output "route53_zone_name_servers" {
  description = "Name servers for the hosted zone — delegate from your registrar to these"
  value       = aws_route53_zone.root.name_servers
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
