variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Short environment label applied to all resource tags"
  type        = string
  default     = "dev"
}

variable "domain" {
  description = "Root domain name (must be registered and delegatable to Route53, e.g. example.com)"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the platform VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of AZs to use (must have at least 2)"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "route53_zone_id" {
  description = <<-EOT
    ID of a pre-existing Route53 public hosted zone for var.domain.
    When set, Terraform uses the existing zone instead of creating one.
    Use this when the account already has a hosted zone you can't manage
    via Terraform. Leave empty when Terraform should create the zone
    from scratch and you'll delegate the domain at your registrar.
  EOT
  type        = string
  default     = ""
}

variable "cognito_test_user_email" {
  description = "Email for the Cognito test user. Leave empty to skip test-user creation (pool still created)."
  type        = string
  default     = ""
}

variable "cognito_test_user_password" {
  description = "Temporary password for the Cognito test user (must meet pool complexity rules). Leave empty if cognito_test_user_email is empty."
  type        = string
  sensitive   = true
  default     = ""
}
