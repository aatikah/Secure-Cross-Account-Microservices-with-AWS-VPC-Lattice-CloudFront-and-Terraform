variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "ecommerce"
}

variable "account_b_id" {
  description = "Account B (consumer) AWS Account ID"
  type        = string
}

variable "customer_ou_arn" {
  description = "Customer Organization Unit ARN"
  type        = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  type    = string
  default = "10.0.10.0/24"
}

variable "private_subnet_a_cidr" {
  type    = string
  default = "10.0.1.0/24"
}

variable "private_subnet_b_cidr" {
  type    = string
  default = "10.0.2.0/24"
}

variable "instance_type" {
  type    = string
  default = "t2.micro"
}
