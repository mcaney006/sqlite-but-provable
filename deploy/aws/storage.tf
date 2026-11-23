# The database directory lives on EFS so that it outlives the task.

resource "aws_efs_file_system" "this" {
  creation_token  = var.name
  encrypted       = true
  kms_key_id      = var.kms_key_arn
  throughput_mode = "elastic"

  tags = merge(var.tags, { Name = var.name })
}

resource "aws_efs_backup_policy" "this" {
  file_system_id = aws_efs_file_system.this.id

  backup_policy {
    status = var.enable_backups ? "ENABLED" : "DISABLED"
  }
}

# The access point fixes the directory and the POSIX user, which is the
# user the image runs as.
resource "aws_efs_access_point" "this" {
  file_system_id = aws_efs_file_system.this.id

  posix_user {
    uid = 10001
    gid = 10001
  }

  root_directory {
    path = "/idrisql"

    creation_info {
      owner_uid   = 10001
      owner_gid   = 10001
      permissions = "0750"
    }
  }

  tags = merge(var.tags, { Name = var.name })
}

resource "aws_efs_mount_target" "this" {
  for_each = local.subnets

  file_system_id  = aws_efs_file_system.this.id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs.id]
}

data "aws_iam_policy_document" "efs" {
  statement {
    sid    = "TaskThroughAccessPoint"
    effect = "Allow"
    actions = [
      "elasticfilesystem:ClientMount",
      "elasticfilesystem:ClientWrite",
    ]
    resources = [aws_efs_file_system.this.arn]

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.task.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "elasticfilesystem:AccessPointArn"
      values   = [aws_efs_access_point.this.arn]
    }
  }

  statement {
    sid       = "DenyUnencryptedTransport"
    effect    = "Deny"
    actions   = ["*"]
    resources = [aws_efs_file_system.this.arn]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_efs_file_system_policy" "this" {
  file_system_id = aws_efs_file_system.this.id
  policy         = data.aws_iam_policy_document.efs.json
}
