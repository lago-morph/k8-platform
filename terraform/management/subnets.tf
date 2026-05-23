# Dedicated private subnets for the management cluster nodes.
# Using a separate /24 per AZ keeps management traffic isolated from the
# shared private subnets in the base module.
#
# CIDR allocation: base module uses .0.x (public) and .10.x (private shared).
# Management cluster uses .20.x and .21.x to avoid overlap.

locals {
  base_vpc_id          = try(data.terraform_remote_state.base.outputs.vpc_id, "")
  base_nat_gateway_ids = try(data.terraform_remote_state.base.outputs.nat_gateway_ids, [])
  base_applied         = local.base_vpc_id != ""
}

resource "aws_subnet" "management" {
  count = length(var.availability_zones)

  vpc_id            = local.base_vpc_id
  cidr_block        = "10.0.${20 + count.index}.0/24"
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name                                        = "k8-platform-mgmt-${var.availability_zones[count.index]}"
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }
}

# Route management subnet traffic through the shared NAT gateways in the
# base module.  NAT gateways are indexed by AZ so traffic stays in-AZ.
# Skipped when base hasn't been applied yet (vpc_id is empty).
data "aws_nat_gateways" "base" {
  count  = local.base_applied ? 1 : 0
  vpc_id = local.base_vpc_id

  filter {
    name   = "tag:Project"
    values = ["k8-platform"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

resource "aws_route_table" "management" {
  count  = length(var.availability_zones)
  vpc_id = local.base_vpc_id

  # Route to the NAT gateway in the same AZ.
  # We rely on the fact that the base module creates NAT GWs in the same AZ
  # order as var.availability_zones — confirmed by the base outputs.
  # The dynamic block is skipped when base hasn't been applied (empty list).
  dynamic "route" {
    for_each = local.base_applied ? [count.index] : []
    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = local.base_nat_gateway_ids[route.value]
    }
  }

  tags = { Name = "k8-platform-mgmt-rt-${var.availability_zones[count.index]}" }
}

resource "aws_route_table_association" "management" {
  count = length(var.availability_zones)

  subnet_id      = aws_subnet.management[count.index].id
  route_table_id = aws_route_table.management[count.index].id
}
