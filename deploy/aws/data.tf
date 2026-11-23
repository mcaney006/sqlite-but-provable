data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_region" "current" {}

locals {
  account_id     = data.aws_caller_identity.current.account_id
  partition      = data.aws_partition.current.partition
  region         = data.aws_region.current.region
  container_port = 5480
  listener_port  = var.certificate_arn == null ? 80 : 443
  cluster_arn    = var.create_cluster ? aws_ecs_cluster.this[0].arn : var.cluster_arn
  token_arn      = var.create_token_secret ? aws_secretsmanager_secret.token[0].arn : var.token_secret_arn

  # Keyed by position, so that ids not known until apply can be used.
  subnets       = { for i, id in var.private_subnet_ids : tostring(i) => id }
  client_cidrs  = { for i, cidr in var.allowed_cidr_blocks : tostring(i) => cidr }
  client_groups = { for i, id in var.allowed_security_group_ids : tostring(i) => id }
}
