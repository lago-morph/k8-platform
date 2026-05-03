resource "aws_route53_zone" "root" {
  name = var.domain

  tags = { Name = var.domain }
}
