# networking.tf — VPC and networking configuration
#
# TASK: This file contains 3 bugs. Find and fix them.
# The infrastructure should create a production-grade VPC with
# public and private subnets across 2 AZs.

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.cluster_name}-vpc"
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

# --- Public Subnets ---

resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 1)
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name                     = "${var.cluster_name}-public-a"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 2)
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = true

  tags = {
    Name                     = "${var.cluster_name}-public-b"
    "kubernetes.io/role/elb" = "1"
  }
}

# --- Private Subnets ---

resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 10)
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = {
    Name                              = "${var.cluster_name}-private-a"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 11)
  availability_zone = data.aws_availability_zones.available.names[1]

  tags = {
    Name                              = "${var.cluster_name}-private-b"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# --- Internet Gateway ---

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.cluster_name}-igw"
  }
}

# --- NAT Gateway ---

resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  # FIX (Bug 1): NAT Gateway must be placed in a public subnet. It needs a route to the
  # Internet Gateway to forward outbound traffic from private subnets. Placing it in a
  # private subnet leaves it with no internet path — private nodes can't reach ECR, S3,
  # or the EKS control plane, and node group provisioning fails entirely.
  subnet_id     = aws_subnet.public_a.id

  tags = {
    Name = "${var.cluster_name}-nat"
  }
}

# --- Route Tables ---

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.cluster_name}-public-rt"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "${var.cluster_name}-private-rt"
  }
}

# FIX (Bug 2): Public subnets must be associated with the public route table (0.0.0.0/0 → IGW),
# not the private one (0.0.0.0/0 → NAT). Using the private route table here would route
# internet-facing traffic through NAT, breaking EKS load balancers (tagged
# kubernetes.io/role/elb=1) and the bastion host that depend on direct IGW access.

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private.id
}

# --- Security Groups ---

resource "aws_security_group" "bastion" {
  name_prefix = "${var.cluster_name}-bastion-"
  vpc_id      = aws_vpc.main.id

  # FIX (Bug 3): SSH was open to 0.0.0.0/0 (the entire internet), violating least-privilege.
  # An internet-exposed SSH port invites brute-force and credential-stuffing attacks and is
  # a common initial-access vector. Restricted to var.management_cidr — the operator's known
  # network (e.g. corporate VPN or on-prem management subnet per site_spec.json: 10.50.1.0/24).
  # The variable includes a validation rule that hard-blocks 0.0.0.0/0 from being passed in,
  # preventing accidental reintroduction of the open default across any environment.
  ingress {
    description = "SSH from management network only"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.management_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.cluster_name}-bastion-sg"
  }
}

resource "aws_security_group" "eks_nodes" {
  name_prefix = "${var.cluster_name}-nodes-"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Node to node"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.cluster_name}-nodes-sg"
  }
}
