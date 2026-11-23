resource "aws_ecs_cluster" "this" {
  count = var.create_cluster ? 1 : 0

  name = var.name

  setting {
    name  = "containerInsights"
    value = var.container_insights
  }

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.name}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_ecs_task_definition" "this" {
  family                   = var.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    cpu_architecture        = var.cpu_architecture
    operating_system_family = "LINUX"
  }

  volume {
    name = "data"

    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.this.id
      transit_encryption = "ENABLED"

      authorization_config {
        access_point_id = aws_efs_access_point.this.id
        iam             = "ENABLED"
      }
    }
  }

  container_definitions = jsonencode([
    {
      name      = "idrisql"
      image     = var.image
      essential = true

      portMappings = [
        { containerPort = local.container_port, protocol = "tcp" }
      ]

      environment = concat(
        [
          { name = "IDRISQL_DATABASE", value = "/data/main.idb" },
          { name = "IDRISQL_PORT", value = tostring(local.container_port) },
          { name = "IDRISQL_MAX_ROWS", value = tostring(var.max_rows) },
        ],
        var.break_stale_lock ? [{ name = "IDRISQL_BREAK_LOCK", value = "1" }] : [],
      )

      secrets = [
        { name = "IDRISQL_TOKEN", valueFrom = local.token_arn }
      ]

      mountPoints = [
        { sourceVolume = "data", containerPath = "/data", readOnly = false }
      ]

      # The server writes nowhere but the database directory.
      readonlyRootFilesystem = true

      linuxParameters = {
        capabilities = { drop = ["ALL"] }
      }

      # Fargate's longest wait between SIGTERM and SIGKILL. The entry point
      # turns SIGTERM into a clean close, which writes a checkpoint.
      stopTimeout = 120

      # The task keeps running if CloudWatch is unreachable; log lines can
      # then be dropped once the buffer is full.
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.this.name
          "awslogs-region"        = local.region
          "awslogs-stream-prefix" = "idrisql"
          "mode"                  = "non-blocking"
          "max-buffer-size"       = "25m"
        }
      }
    }
  ])

  tags = var.tags
}

resource "aws_ecs_service" "this" {
  name            = var.name
  cluster         = local.cluster_arn
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  # One process per database. With these two values ECS never asks for a
  # second running task. A task that is still stopping does not count
  # towards the maximum, so its replacement can start before it has gone;
  # the image's entry point makes the replacement wait for it. Do not raise
  # either value.
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  # Rebalancing starts the replacement before stopping the original, which
  # needs a maximum above 100 percent.
  availability_zone_rebalancing = "DISABLED"

  # A new task can wait for the old one's stop timeout and then for its
  # heartbeat to go stale before it opens the database.
  health_check_grace_period_seconds = 300
  enable_execute_command            = false
  propagate_tags                    = "SERVICE"

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.this.arn
    container_name   = "idrisql"
    container_port   = local.container_port
  }

  depends_on = [
    aws_lb_listener.this,
    aws_efs_mount_target.this,
    aws_efs_file_system_policy.this,
    aws_iam_role_policy.execution,
    aws_iam_role_policy.task,
    aws_iam_role_policy_attachment.execution,
    aws_secretsmanager_secret_version.token,
  ]

  tags = var.tags
}
