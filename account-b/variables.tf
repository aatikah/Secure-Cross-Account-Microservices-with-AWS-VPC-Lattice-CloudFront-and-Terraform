variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "ecommerce"
}


variable "vpc_cidr" {
  description = "Must NOT overlap with Account A (10.0.0.0/16)"
  type        = string
  default     = "10.1.0.0/16"
}

variable "public_subnet_a_cidr" {
  type    = string
  default = "10.1.10.0/24"
}

variable "public_subnet_b_cidr" {
  type    = string
  default = "10.1.11.0/24"
}

variable "private_subnet_cidr" {
  type    = string
  default = "10.1.1.0/24"
}

variable "instance_type" {
  type    = string
  default = "t2.micro"
}


