terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
  backend "s3" {
    bucket       = "my-ecommerce-state-bucket"
    key          = "ecommerce/account-a/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    profile      = "account-a"
  }
}

provider "aws" {
  region  = var.aws_region
  profile = "account-a"
}

data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" { state = "available" }


data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_ec2_managed_prefix_list" "vpc_lattice" {
  name = "com.amazonaws.${var.aws_region}.vpc-lattice"
}

locals {
  account_a_id = data.aws_caller_identity.current.account_id
  az_a         = data.aws_availability_zones.available.names[0]
  az_b         = data.aws_availability_zones.available.names[1]
}

# ── VPC ──────────────────────────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.project}-provider-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project}-provider-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = local.az_a
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.project}-provider-public" }
}

resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_a_cidr
  availability_zone = local.az_a
  tags              = { Name = "${var.project}-provider-private-a" }
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_b_cidr
  availability_zone = local.az_b
  tags              = { Name = "${var.project}-provider-private-b" }
}

resource "aws_eip" "nat" { domain = "vpc" }

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  tags          = { Name = "${var.project}-provider-nat" }
  depends_on    = [aws_internet_gateway.igw]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "${var.project}-provider-public-rt" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  tags = { Name = "${var.project}-provider-private-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
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

# ── IAM ──────────────────────────────────────────────────────

resource "aws_iam_role" "ec2" {
  name = "${var.project}-provider-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "lattice_invoke" {
  name = "lattice-invoke"
  role = aws_iam_role.ec2.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "vpc-lattice-svcs:Invoke"
      Resource = "*"
    }]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project}-provider-ec2-profile"
  role = aws_iam_role.ec2.name
}

# ── Security Groups ───────────────────────────────────────────

resource "aws_security_group" "orders" {
  name        = "${var.project}-orders-sg"
  description = "Inbound from VPC Lattice prefix list only"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.vpc_lattice.id]
    description     = "From VPC Lattice"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-orders-sg" }
}

resource "aws_security_group" "products" {
  name        = "${var.project}-products-sg"
  description = "Inbound from VPC Lattice prefix list only"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.vpc_lattice.id]
    description     = "From VPC Lattice"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-products-sg" }
}

resource "aws_security_group" "lattice_assoc" {
  name        = "${var.project}-provider-lattice-assoc-sg"
  description = "Provider VPC Lattice association"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-provider-lattice-assoc-sg" }
}

# ── EC2 Instances ─────────────────────────────────────────────

resource "aws_instance" "orders" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.private_a.id
  vpc_security_group_ids = [aws_security_group.orders.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  user_data_base64       = base64encode(file("${path.module}/userdata/orders-service.sh"))
  tags                   = { Name = "${var.project}-orders-service" }
}

resource "aws_instance" "products" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.private_b.id
  vpc_security_group_ids = [aws_security_group.products.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  user_data_base64       = base64encode(file("${path.module}/userdata/products-service.sh"))
  tags                   = { Name = "${var.project}-products-service" }
}

# ── VPC Lattice Target Groups ─────────────────────────────────

resource "aws_vpclattice_target_group" "orders" {
  name = "${var.project}-orders-tg"
  type = "INSTANCE"

  config {
    vpc_identifier = aws_vpc.main.id
    port           = 8080
    protocol       = "HTTP"
    health_check {
      enabled                       = true
      path                          = "/health"
      port                          = 8080
      protocol                      = "HTTP"
      protocol_version              = "HTTP1"
      healthy_threshold_count       = 2
      unhealthy_threshold_count     = 2
      health_check_interval_seconds = 30
      health_check_timeout_seconds  = 5
      matcher { value = "200" }
    }
  }

  tags = { Name = "${var.project}-orders-tg" }
}

resource "aws_vpclattice_target_group_attachment" "orders" {
  target_group_identifier = aws_vpclattice_target_group.orders.id
  target {
    id   = aws_instance.orders.id
    port = 8080
  }

   depends_on = [
    aws_vpclattice_listener.orders
  ]
  
}

resource "aws_vpclattice_target_group" "products" {
  name = "${var.project}-products-tg"
  type = "INSTANCE"

  config {
    vpc_identifier = aws_vpc.main.id
    port           = 8080
    protocol       = "HTTP"
    health_check {
      enabled                       = true
      path                          = "/health"
      port                          = 8080
      protocol                      = "HTTP"
      protocol_version              = "HTTP1"
      healthy_threshold_count       = 2
      unhealthy_threshold_count     = 2
      health_check_interval_seconds = 30
      health_check_timeout_seconds  = 5
      matcher { value = "200" }
    }
  }

  tags = { Name = "${var.project}-products-tg" }
}

resource "aws_vpclattice_target_group_attachment" "products" {
  target_group_identifier = aws_vpclattice_target_group.products.id
  target {
    id   = aws_instance.products.id
    port = 8080
  }

  depends_on = [
    aws_vpclattice_listener.products
  ]
}

# ── VPC Lattice Services ──────────────────────────────────────

resource "aws_vpclattice_service" "orders" {
  name      = "${var.project}-orders-svc"
  auth_type = "AWS_IAM"
  tags      = { Name = "${var.project}-orders-svc" }
}

resource "aws_vpclattice_auth_policy" "orders" {
  resource_identifier = aws_vpclattice_service.orders.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        AWS = [
          "arn:aws:iam::${local.account_a_id}:root",
          "arn:aws:iam::${var.account_b_id}:root"
        ]
      }
      Action   = "vpc-lattice-svcs:Invoke"
      Resource = "*"
    }]
  })
}

resource "aws_vpclattice_listener" "orders" {
  name               = "${var.project}-orders-listener"
  service_identifier = aws_vpclattice_service.orders.id
  protocol           = "HTTP"
  port               = 80

  default_action {
    forward {
      target_groups {
        target_group_identifier = aws_vpclattice_target_group.orders.id
        weight                  = 100
      }
    }
  }
}

resource "aws_vpclattice_service" "products" {
  name      = "${var.project}-products-svc"
  auth_type = "AWS_IAM"
  tags      = { Name = "${var.project}-products-svc" }
}

resource "aws_vpclattice_auth_policy" "products" {
  resource_identifier = aws_vpclattice_service.products.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        AWS = [
          "arn:aws:iam::${local.account_a_id}:root",
          "arn:aws:iam::${var.account_b_id}:root"
        ]
      }
      Action   = "vpc-lattice-svcs:Invoke"
      Resource = "*"
    }]
  })
}

resource "aws_vpclattice_listener" "products" {
  name               = "${var.project}-products-listener"
  service_identifier = aws_vpclattice_service.products.id
  protocol           = "HTTP"
  port               = 80

  default_action {
    forward {
      target_groups {
        target_group_identifier = aws_vpclattice_target_group.products.id
        weight                  = 100
      }
    }
  }
}

# ── VPC Lattice Service Network ───────────────────────────────

resource "aws_vpclattice_service_network" "main" {
  name      = "${var.project}-service-network"
  auth_type = "AWS_IAM"
  tags      = { Name = "${var.project}-service-network" }
}

resource "aws_vpclattice_auth_policy" "service_network" {
  resource_identifier = aws_vpclattice_service_network.main.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        AWS = [
          "arn:aws:iam::${local.account_a_id}:root",
          "arn:aws:iam::${var.account_b_id}:root"
        ]
      }
      Action   = "vpc-lattice-svcs:Invoke"
      Resource = "*"
    }]
  })
}

resource "aws_vpclattice_service_network_service_association" "orders" {
  service_identifier         = aws_vpclattice_service.orders.id
  service_network_identifier = aws_vpclattice_service_network.main.id
}

resource "aws_vpclattice_service_network_service_association" "products" {
  service_identifier         = aws_vpclattice_service.products.id
  service_network_identifier = aws_vpclattice_service_network.main.id
}

resource "aws_vpclattice_service_network_vpc_association" "provider" {
  vpc_identifier             = aws_vpc.main.id
  service_network_identifier = aws_vpclattice_service_network.main.id
  security_group_ids         = [aws_security_group.lattice_assoc.id]
}

# ── CloudWatch Access Logs ────────────────────────────────────

resource "aws_cloudwatch_log_group" "lattice" {
  name              = "/aws/vpc-lattice/${var.project}"
  retention_in_days = 14
  tags              = { Name = "${var.project}-lattice-logs" }
}

resource "aws_vpclattice_access_log_subscription" "main" {
  resource_identifier = aws_vpclattice_service_network.main.arn
  destination_arn     = aws_cloudwatch_log_group.lattice.arn
}

# ── AWS RAM Share ─────────────────────────────────────────────

resource "aws_ram_resource_share" "lattice" {
  name = "${var.project}-lattice-share"
  # allow_external_principals = true
  tags = { Name = "${var.project}-lattice-ram-share" }
}

resource "aws_ram_resource_association" "service_network" {
  resource_arn       = aws_vpclattice_service_network.main.arn
  resource_share_arn = aws_ram_resource_share.lattice.arn

  # depends_on = [aws_ram_sharing_with_organization.main]
}

# resource "aws_ram_sharing_with_organization" "main" {}

resource "aws_ram_principal_association" "customer_ou" {
  principal          = var.customer_ou_arn
  resource_share_arn = aws_ram_resource_share.lattice.arn

  depends_on = [
    # aws_ram_sharing_with_organization.main,
    aws_ram_resource_association.service_network,

  ]
}
