# ACM wildcard certificate for the platform domain.
#
# A single *.{domain} certificate covers every service hostname across all
# clusters (argocd.management.example.com, grafana.platform.example.com, etc.).
# It is attached to each cluster's ingress-nginx NLB so TLS terminates at the
# load balancer — no cert-manager ACME setup needed.
#
# DNS validation via Route53 is fast (typically < 2 minutes) and fully
# automatic.  The aws_acm_certificate_validation resource waits for the cert
# to become ISSUED before the apply completes, so downstream Terraform modules
# that reference the ARN are guaranteed to receive a valid cert.

resource "aws_acm_certificate" "wildcard" {
  domain_name               = "*.${var.domain}"
  subject_alternative_names = [var.domain]
  validation_method         = "DNS"

  # create_before_destroy prevents a brief gap in coverage when the cert is
  # eventually rotated or replaced.
  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "k8-platform-wildcard" }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.wildcard.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = local.zone_id
}

resource "aws_acm_certificate_validation" "wildcard" {
  certificate_arn         = aws_acm_certificate.wildcard.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]

  timeouts {
    create = "10m"
  }
}
