# The bearer token. The value is generated during apply and sent to
# Secrets Manager through a write-only argument, so neither the plan nor
# the state holds it.

ephemeral "random_password" "token" {
  count = var.create_token_secret ? 1 : 0

  length  = 48
  special = false
}

resource "aws_secretsmanager_secret" "token" {
  count = var.create_token_secret ? 1 : 0

  name_prefix = "${var.name}-token-"
  description = "Bearer token for the ${var.name} IdrisQL server"
  kms_key_id  = var.kms_key_arn
  tags        = var.tags
}

resource "aws_secretsmanager_secret_version" "token" {
  count = var.create_token_secret ? 1 : 0

  secret_id                = aws_secretsmanager_secret.token[0].id
  secret_string_wo         = ephemeral.random_password.token[0].result
  secret_string_wo_version = var.token_version
}
