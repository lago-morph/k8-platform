locals {
  name_prefix = "k8-platform"

  # Carve the VPC CIDR into /24 slices for subnets.
  # Public subnets: .0.0/24, .1.0/24, ...
  # Private subnets: .10.0/24, .11.0/24, ...
  public_subnet_cidrs  = [for i, _ in var.availability_zones : cidrsubnet(var.vpc_cidr, 8, i)]
  private_subnet_cidrs = [for i, _ in var.availability_zones : cidrsubnet(var.vpc_cidr, 8, i + 10)]
}
