resource "aws_cognito_user_pool" "main" {
  name = "${local.name_prefix}-users"

  # Require email as username; users authenticate with email + password.
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length                   = 12
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = false
    temporary_password_validity_days = 7
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  tags = { Name = "${local.name_prefix}-users" }
}

# App client used by Keycloak for OIDC federation (Iteration 5).
resource "aws_cognito_user_pool_client" "keycloak" {
  name         = "keycloak"
  user_pool_id = aws_cognito_user_pool.main.id

  generate_secret = true

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]

  # Keycloak redirect URI — must match the Keycloak broker callback.
  # Update <domain> after Keycloak is deployed in Iteration 5.
  callback_urls = ["https://auth.platform.${var.domain}/realms/platform/broker/cognito/endpoint"]
  logout_urls   = ["https://auth.platform.${var.domain}/realms/platform/broker/cognito/endpoint/logout"]

  supported_identity_providers = ["COGNITO"]

  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]
}

# Cognito User Pool domain (required for hosted UI / OIDC discovery endpoint).
resource "aws_cognito_user_pool_domain" "main" {
  domain       = "${local.name_prefix}-${replace(var.domain, ".", "-")}"
  user_pool_id = aws_cognito_user_pool.main.id
}

# Test user — useful for verifying authentication flows without a real email.
resource "aws_cognito_user" "test" {
  user_pool_id = aws_cognito_user_pool.main.id
  username     = var.cognito_test_user_email

  attributes = {
    email          = var.cognito_test_user_email
    email_verified = "true"
  }

  temporary_password = var.cognito_test_user_password

  # Suppress Cognito's "change password on first login" requirement so the
  # test user can authenticate immediately in demos without a UI flow.
  message_action = "SUPPRESS"
}
