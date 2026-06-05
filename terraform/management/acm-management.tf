# Per-subdomain TLS certificate for the management cluster's own services.
#
# WHY THIS EXISTS (the bug it fixes):
# The management ingress publishes ArgoCD (and any future management service) at
# <svc>.management.<domain> — e.g. argocd.management.<domain>. The base account
# wildcard `*.<domain>` (terraform/base) matches only ONE DNS label in the
# wildcard position, so it covers `management.<domain>` and `argocd.<domain>` but
# does NOT cover `argocd.management.<domain>` (two labels: `argocd.management`).
# The ingress-nginx NLB was serving that base cert on its :443 TLS listener, so
# the cert it presented did not name-match the host.
#
# Most clients never noticed because the project's CI verify uses `curl -sk`
# (-k skips cert verification) and browsers were not exercised. But a STRICT
# TLS client — the Claude-Code-web sandbox's egress gateway (an Envoy MITM that
# verifies the upstream SAN) — rejected it with
# `CERTIFICATE_VERIFY_FAILED: verify cert failed: verify SAN list` and returned
# 503, which blocked driving ArgoCD from the sandbox. See OI-2026-06-05-5 and
# retrospective 2026-06-05-148; decision auto-007 (option B).
#
# FIX: issue a DNS-validated cert that actually covers the management subdomain
# (`*.management.<domain>` + the apex `management.<domain>`) and put THAT on the
# ingress NLB's TLS listener (helm.tf `aws-load-balancer-ssl-cert`). The in-tree
# AWS cloud-controller supports a single cert per listener, and the management
# NLB only ever serves `*.management.<domain>` hosts, so this cert is the correct
# and complete coverage. The base `*.<domain>` cert stays in terraform/base for
# resources that are genuinely one label under the apex.
resource "aws_acm_certificate" "management" {
  domain_name               = "*.management.${var.domain}"
  subject_alternative_names = ["management.${var.domain}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name      = "${var.cluster_name}-management-tls"
    ManagedBy = "terraform"
    Cluster   = var.cluster_name
  }
}

# DNS-validation CNAMEs, written into the base hosted zone (zone_id comes from
# the base remote state — see irsa.tf locals).
resource "aws_route53_record" "management_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.management.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id         = local.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "management" {
  certificate_arn         = aws_acm_certificate.management.arn
  validation_record_fqdns = [for r in aws_route53_record.management_cert_validation : r.fqdn]
}

# The validated cert ARN — consumed by the ingress-nginx NLB ssl-cert annotation
# (helm.tf). Referencing the *_validation resource enforces that the cert is
# ISSUED before the ingress (and thus the NLB listener) is created.
locals {
  management_acm_certificate_arn = aws_acm_certificate_validation.management.certificate_arn
}

output "management_acm_certificate_arn" {
  description = "ACM cert covering *.management.<domain> (the management ingress NLB TLS listener cert)."
  value       = aws_acm_certificate_validation.management.certificate_arn
}
