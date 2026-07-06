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

# Test user — only created when cognito_test_user_email is set.
# Skipping this resource is safe for CI plan/apply cycles; it is only needed
# when interactively testing SSO flows in Iteration 5.
resource "aws_cognito_user" "test" {
  count        = var.cognito_test_user_email != "" ? 1 : 0
  user_pool_id = aws_cognito_user_pool.main.id
  username     = var.cognito_test_user_email

  attributes = {
    email          = var.cognito_test_user_email
    email_verified = "true"
  }

  temporary_password = var.cognito_test_user_password
  message_action     = "SUPPRESS"
}

# The Kubernetes access groups (REQ-AUTH-08/09). Group membership HERE is
# what grants cluster access: Keycloak copies `cognito:groups` into the
# `groups` token claim on every brokered login, and the EKS identity
# provider config prefixes them `kc:` for the kc-* ClusterRoleBindings
# (clusters/platform/rbac/). No group state exists in Keycloak (REQ-AUTH-08).
resource "aws_cognito_user_group" "k8s_admins" {
  name         = "k8s-admins"
  user_pool_id = aws_cognito_user_pool.main.id
  description  = "Members get cluster-admin on the platform services cluster via the kc-prefixed group binding"
}

resource "aws_cognito_user_group" "k8s_viewers" {
  name         = "k8s-viewers"
  user_pool_id = aws_cognito_user_pool.main.id
  description  = "Members get read-only view on the platform services cluster via the kc-prefixed group binding"
}

# The Keycloak broker's federation inputs, delivered through ASM under the
# platform's deterministic naming so a COMMITTED spoke ExternalSecret can
# pull them (the same live-proven transport the keycloak-admin secret uses).
# The confidential client secret is COGNITO-generated — it cannot ride the
# XPlatformSecret chain, whose ADR-0012 material chain generates its own
# random value; Terraform is this value's source of truth, so Terraform
# writes the container. Tags deliberately do NOT carry
# PlatformAbstraction=PlatformSecret: the live-verify secretsmanager check
# selects on that tag pair and must keep seeing only Composition-owned
# containers.
#
# recovery_window_in_days = 0: the account is ephemeral and CI rebuilds
# from scratch; a deletion recovery window would block re-creates under
# the same deterministic name (same reasoning as the PlatformSecret
# Composition).
resource "aws_secretsmanager_secret" "cognito_idp" {
  name                    = "k8-platform/base/cognito"
  description             = "Cognito federation endpoints and confidential client for the Keycloak broker - REQ-AUTH-02/08"
  recovery_window_in_days = 0

  tags = {
    Name      = "${local.name_prefix}-cognito-idp"
    ManagedBy = "terraform"
  }
}

# One JSON document carrying every value the realm import substitutes
# (platform-services/keycloak/spoke/realm-platform-configmap.yaml reads
# them as ${KC_COGNITO_*} container env; the spoke ExternalSecret
# keycloak-cognito-idp materializes this document key-for-key). The
# authorize/token/userInfo/logout endpoints live on the hosted-UI domain;
# issuer + jwks live on the cognito-idp API host.
resource "aws_secretsmanager_secret_version" "cognito_idp" {
  secret_id = aws_secretsmanager_secret.cognito_idp.id
  secret_string = jsonencode({
    client_id         = aws_cognito_user_pool_client.keycloak.id
    client_secret     = aws_cognito_user_pool_client.keycloak.client_secret
    issuer_url        = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.main.id}"
    authorization_url = "https://${aws_cognito_user_pool_domain.main.domain}.auth.${var.aws_region}.amazoncognito.com/oauth2/authorize"
    token_url         = "https://${aws_cognito_user_pool_domain.main.domain}.auth.${var.aws_region}.amazoncognito.com/oauth2/token"
    user_info_url     = "https://${aws_cognito_user_pool_domain.main.domain}.auth.${var.aws_region}.amazoncognito.com/oauth2/userInfo"
    logout_url        = "https://${aws_cognito_user_pool_domain.main.domain}.auth.${var.aws_region}.amazoncognito.com/logout"
    jwks_url          = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.main.id}/.well-known/jwks.json"
  })
}
