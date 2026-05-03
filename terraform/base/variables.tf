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

variable "cognito_test_user_email" {
  description = "Email address for the Cognito test user created during base setup"
  type        = string
}

variable "cognito_test_user_password" {
  description = "Temporary password for the Cognito test user (must meet Cognito complexity rules)"
  type        = string
  sensitive   = true
}
