resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "${local.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${local.name_prefix}-igw" }
}

# --- Public subnets ---

resource "aws_subnet" "public" {
  count = length(var.availability_zones)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  # Every cluster hosted in this shared VPC needs its own
  # kubernetes.io/cluster/<name>=shared tag here, or its cloud provider
  # excludes these subnets when placing ELBs/NLBs (OI-2026-06-07-3).
  tags = merge(
    {
      Name                                              = "${local.name_prefix}-public-${var.availability_zones[count.index]}"
      "kubernetes.io/role/elb"                          = "1"
      "kubernetes.io/cluster/${local.name_prefix}-mgmt" = "shared"
    },
    { for c in var.hosted_cluster_names : "kubernetes.io/cluster/${c}" => "shared" }
  )
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${local.name_prefix}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count = length(var.availability_zones)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# --- NAT gateways (one per AZ for HA) ---

resource "aws_eip" "nat" {
  count  = length(var.availability_zones)
  domain = "vpc"

  tags = { Name = "${local.name_prefix}-nat-eip-${var.availability_zones[count.index]}" }
}

resource "aws_nat_gateway" "main" {
  count = length(var.availability_zones)

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = { Name = "${local.name_prefix}-nat-${var.availability_zones[count.index]}" }

  depends_on = [aws_internet_gateway.main]
}

# --- Private subnets (shared pool — each cluster gets its own slice in management/vpc.tf) ---

resource "aws_subnet" "private" {
  count = length(var.availability_zones)

  vpc_id            = aws_vpc.main.id
  cidr_block        = local.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  # Same per-hosted-cluster tagging as the public subnets above
  # (OI-2026-06-07-3) — internal ELBs/NLBs need it too.
  tags = merge(
    {
      Name                                              = "${local.name_prefix}-private-${var.availability_zones[count.index]}"
      "kubernetes.io/role/internal-elb"                 = "1"
      "kubernetes.io/cluster/${local.name_prefix}-mgmt" = "shared"
    },
    { for c in var.hosted_cluster_names : "kubernetes.io/cluster/${c}" => "shared" }
  )
}

resource "aws_route_table" "private" {
  count  = length(var.availability_zones)
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[count.index].id
  }

  tags = { Name = "${local.name_prefix}-private-rt-${var.availability_zones[count.index]}" }
}

resource "aws_route_table_association" "private" {
  count = length(var.availability_zones)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}
