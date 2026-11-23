# Three security groups: the load balancer, the task, and the file
# system's mount targets. Each accepts traffic only from the one before.

resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "Load balancer for the ${var.name} IdrisQL server"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-alb" })
}

resource "aws_vpc_security_group_ingress_rule" "alb_cidr" {
  for_each = local.client_cidrs

  security_group_id = aws_security_group.alb.id
  description       = "Clients"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = local.listener_port
  to_port           = local.listener_port
}

resource "aws_vpc_security_group_ingress_rule" "alb_group" {
  for_each = local.client_groups

  security_group_id            = aws_security_group.alb.id
  description                  = "Clients"
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = local.listener_port
  to_port                      = local.listener_port
}

resource "aws_vpc_security_group_egress_rule" "alb_to_task" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Requests and health checks"
  referenced_security_group_id = aws_security_group.task.id
  ip_protocol                  = "tcp"
  from_port                    = local.container_port
  to_port                      = local.container_port
}

resource "aws_security_group" "task" {
  name        = "${var.name}-task"
  description = "The ${var.name} IdrisQL server"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-task" })
}

resource "aws_vpc_security_group_ingress_rule" "task_from_alb" {
  security_group_id            = aws_security_group.task.id
  description                  = "Requests and health checks"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = local.container_port
  to_port                      = local.container_port
}

# Image pull, CloudWatch Logs and Secrets Manager.
resource "aws_vpc_security_group_egress_rule" "task_https" {
  security_group_id = aws_security_group.task.id
  description       = "Image registry and AWS APIs"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "task_to_efs" {
  security_group_id            = aws_security_group.task.id
  description                  = "Database files"
  referenced_security_group_id = aws_security_group.efs.id
  ip_protocol                  = "tcp"
  from_port                    = 2049
  to_port                      = 2049
}

resource "aws_security_group" "efs" {
  name        = "${var.name}-efs"
  description = "File system of the ${var.name} IdrisQL server"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-efs" })
}

resource "aws_vpc_security_group_ingress_rule" "efs_from_task" {
  security_group_id            = aws_security_group.efs.id
  description                  = "NFS from the task"
  referenced_security_group_id = aws_security_group.task.id
  ip_protocol                  = "tcp"
  from_port                    = 2049
  to_port                      = 2049
}

resource "aws_lb" "this" {
  name                       = var.name
  internal                   = true
  load_balancer_type         = "application"
  subnets                    = var.private_subnet_ids
  security_groups            = [aws_security_group.alb.id]
  idle_timeout               = var.idle_timeout_seconds
  drop_invalid_header_fields = true
  tags                       = var.tags
}

resource "aws_lb_target_group" "this" {
  name                 = "${var.name}-tg"
  vpc_id               = var.vpc_id
  port                 = local.container_port
  protocol             = "HTTP"
  target_type          = "ip"
  deregistration_delay = 30

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = var.health_check_unhealthy_threshold
  }

  tags = var.tags
}

resource "aws_lb_listener" "this" {
  load_balancer_arn = aws_lb.this.arn
  port              = local.listener_port
  protocol          = var.certificate_arn == null ? "HTTP" : "HTTPS"
  certificate_arn   = var.certificate_arn
  ssl_policy        = var.certificate_arn == null ? null : "ELBSecurityPolicy-TLS13-1-2-2021-06"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }

  tags = var.tags
}
