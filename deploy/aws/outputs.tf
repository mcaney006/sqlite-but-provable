output "endpoint" {
  description = "Base URL of the server, reachable from the allowed networks. It uses the load balancer's own name, which a certificate for your domain does not cover: with certificate_arn set, point a DNS alias at load_balancer_dns_name and use that name."
  value       = "${var.certificate_arn == null ? "http" : "https"}://${aws_lb.this.dns_name}"
}

output "load_balancer_dns_name" {
  description = "DNS name of the load balancer, for an alias record."
  value       = aws_lb.this.dns_name
}

output "load_balancer_zone_id" {
  description = "Hosted zone of the load balancer, for an alias record."
  value       = aws_lb.this.zone_id
}

output "load_balancer_security_group_id" {
  description = "Security group of the load balancer."
  value       = aws_security_group.alb.id
}

output "token_secret_arn" {
  description = "Secrets Manager secret that holds the bearer token."
  value       = local.token_arn
}

output "cluster_arn" {
  description = "ECS cluster the service runs in."
  value       = local.cluster_arn
}

output "service_name" {
  description = "Name of the ECS service."
  value       = aws_ecs_service.this.name
}

output "file_system_id" {
  description = "EFS file system that holds the database."
  value       = aws_efs_file_system.this.id
}

output "log_group_name" {
  description = "CloudWatch log group of the server."
  value       = aws_cloudwatch_log_group.this.name
}
