terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = "account-b"
}

data "terraform_remote_state" "account_a" {
  backend = "s3"
  config = {
    bucket  = "my-ecommerce-state-bucket"
    key     = "ecommerce/account-a/terraform.tfstate"
    region  = "us-east-1"
    profile = "account-a"
  }
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

data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

locals {
  az_a = data.aws_availability_zones.available.names[0]
  az_b = data.aws_availability_zones.available.names[1]
}

# ── VPC ──────────────────────────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.project}-consumer-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project}-consumer-igw" }
}

resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_a_cidr
  availability_zone       = local.az_a
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.project}-consumer-public-a" }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_b_cidr
  availability_zone       = local.az_b
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.project}-consumer-public-b" }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidr
  availability_zone = local.az_a
  tags              = { Name = "${var.project}-consumer-private" }
}

resource "aws_eip" "nat" { domain = "vpc" }

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_a.id
  tags          = { Name = "${var.project}-consumer-nat" }
  depends_on    = [aws_internet_gateway.igw]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "${var.project}-consumer-public-rt" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  tags = { Name = "${var.project}-consumer-private-rt" }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# ── IAM ──────────────────────────────────────────────────────

resource "aws_iam_role" "consumer_ec2" {
  name = "${var.project}-consumer-ec2-role"
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
  role       = aws_iam_role.consumer_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "lattice_invoke" {
  role       = aws_iam_role.consumer_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/VPCLatticeServicesInvokeAccess"
}

resource "aws_iam_instance_profile" "consumer_ec2" {
  name = "${var.project}-consumer-ec2-profile"
  role = aws_iam_role.consumer_ec2.name
}

# ── Security Groups ───────────────────────────────────────────

# ALB — accepts port 80 from CloudFront managed prefix list only
resource "aws_security_group" "alb" {
  name        = "${var.project}-consumer-alb-sg"
  description = "ALB: inbound HTTP from CloudFront only"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront.id]
    description     = "HTTP from CloudFront"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-consumer-alb-sg" }
}

# Consumer EC2 — accepts port 8080 from ALB SG only
resource "aws_security_group" "consumer_ec2" {
  name        = "${var.project}-consumer-ec2-sg"
  description = "Consumer EC2: inbound 8080 from ALB only"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
    description     = "From ALB"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-consumer-ec2-sg" }
}

# Lattice VPC association SG
# CRITICAL: needs BOTH inbound (from VPC CIDR) AND outbound.
# Without inbound rules you get Errno 101 Network unreachable.
resource "aws_security_group" "lattice_assoc" {
  name        = "${var.project}-consumer-lattice-assoc-sg"
  description = "VPC association with shared Lattice service network"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "HTTP from consumer VPC"
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "HTTPS from consumer VPC"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-consumer-lattice-assoc-sg" }
}

# ── Consumer EC2 ──────────────────────────────────────────────

resource "aws_instance" "consumer" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.consumer_ec2.id]
  iam_instance_profile   = aws_iam_instance_profile.consumer_ec2.name

  user_data_base64 = base64encode(templatefile("${path.module}/userdata/consumer.sh.tpl", {
    orders_dns   = data.terraform_remote_state.account_a.outputs.orders_service_dns
    products_dns = data.terraform_remote_state.account_a.outputs.products_service_dns
    aws_region   = var.aws_region
  }))

  tags = { Name = "${var.project}-consumer" }
}

# ── VPC Lattice — VPC Association ────────────────────────────
# Associates Account B VPC with the Service Network shared from Account A.
# RAM share must be accepted before terraform apply.

resource "aws_vpclattice_service_network_vpc_association" "consumer" {
  vpc_identifier             = aws_vpc.main.id
  service_network_identifier = data.terraform_remote_state.account_a.outputs.service_network_id
  security_group_ids         = [aws_security_group.lattice_assoc.id]
  tags                       = { Name = "${var.project}-consumer-vpc-association" }

  depends_on = [
    aws_vpc.main,
    aws_security_group.lattice_assoc
  ]

}

# ── ALB ───────────────────────────────────────────────────────

resource "aws_lb" "public" {
  name               = "${var.project}-consumer-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_b.id]
  tags               = { Name = "${var.project}-consumer-alb" }
}

resource "aws_lb_target_group" "consumer" {
  name        = "${var.project}-consumer-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    enabled             = true
    path                = "/health"
    port                = "8080"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
    matcher             = "200"
  }

  tags = { Name = "${var.project}-consumer-tg" }
}

resource "aws_lb_target_group_attachment" "consumer" {
  target_group_arn = aws_lb_target_group.consumer.arn
  target_id        = aws_instance.consumer.id
  port             = 8080

  depends_on = [
    aws_lb_listener.http
  ]
  
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.public.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.consumer.arn
  }
}

# ── CloudFront ────────────────────────────────────────────────
# Viewer  → CloudFront : HTTPS  (redirect-to-https)
# CloudFront → ALB     : HTTP   (origin_protocol_policy = http-only)

resource "aws_cloudfront_distribution" "main" {
  enabled = true
  comment = "${var.project} storefront"

  origin {
    domain_name = aws_lb.public.dns_name
    origin_id   = "alb-consumer"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "alb-consumer"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]

    forwarded_values {
      query_string = true
      headers      = ["Host", "Authorization", "Content-Type"]
      cookies { forward = "none" }
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }

  ordered_cache_behavior {
    path_pattern           = "/api/*"
    target_origin_id       = "alb-consumer"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]

    forwarded_values {
      query_string = true
      headers      = ["Host", "Authorization", "Content-Type"]
      cookies { forward = "none" }
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = { Name = "${var.project}-cloudfront" }
}
