# One IdrisQL server in an existing VPC, reachable from one network range.
#
#   terraform init
#   terraform plan -var vpc_id=vpc-... -var 'private_subnet_ids=["subnet-...","subnet-..."]' \
#     -var 'allowed_cidr_blocks=["10.0.0.0/16"]' -var image=ghcr.io/mcaney006/sqlite-but-provable:0.2.0

terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.73, < 7.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "idrisql"
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}

variable "region" {
  description = "Region to deploy into."
  type        = string
  default     = "us-east-2"
}

variable "vpc_id" {
  description = "VPC to deploy into."
  type        = string
}

variable "private_subnet_ids" {
  description = "Two or more private subnets in different Availability Zones."
  type        = list(string)
}

variable "allowed_cidr_blocks" {
  description = "Networks that may reach the server."
  type        = list(string)
}

variable "image" {
  description = "Container image with a version tag or digest."
  type        = string
}

module "idrisql" {
  source = "../.."

  name                = "idrisql-dev"
  image               = var.image
  vpc_id              = var.vpc_id
  private_subnet_ids  = var.private_subnet_ids
  allowed_cidr_blocks = var.allowed_cidr_blocks
}

output "endpoint" {
  description = "Base URL of the server."
  value       = module.idrisql.endpoint
}

output "token_secret_arn" {
  description = "Secret that holds the bearer token."
  value       = module.idrisql.token_secret_arn
}
