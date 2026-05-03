# Route53 hosted zone.
#
# Two modes controlled by var.route53_zone_id:
#
#   ""  (default) — Terraform creates a new zone. Use this for real deployments
#       where you own the domain and want Terraform to manage the zone lifecycle.
#       After apply, delegate the domain at your registrar to the output
#       name servers before DNS validation will work.
#
#   "<zone-id>" — Terraform looks up the existing zone and uses it. Use this
#       for Pluralsight sandboxes (and any other environment where a hosted
#       zone is pre-provisioned). No delegation step is needed.

resource "aws_route53_zone" "root" {
  count = var.route53_zone_id == "" ? 1 : 0
  name  = var.domain
  tags  = { Name = var.domain }
}

data "aws_route53_zone" "existing" {
  count        = var.route53_zone_id != "" ? 1 : 0
  zone_id      = var.route53_zone_id
  private_zone = false
}

locals {
  zone_id = (
    var.route53_zone_id != ""
    ? data.aws_route53_zone.existing[0].zone_id
    : aws_route53_zone.root[0].zone_id
  )
  zone_name_servers = (
    var.route53_zone_id != ""
    ? []
    : aws_route53_zone.root[0].name_servers
  )
}
