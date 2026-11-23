variable "name" {
  description = "Name for the service and the resources created for it."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,22}[a-z0-9]$", var.name))
    error_message = "name must be 3 to 24 characters: lower-case letters, digits and hyphens, starting with a letter and not ending with a hyphen."
  }
}

variable "image" {
  description = "Container image, with a version tag or a digest. Fargate must be able to pull it: a public image needs a route to the internet, an image in ECR needs the ECR endpoints or a NAT gateway."
  type        = string

  validation {
    condition     = !endswith(var.image, ":latest") && (strcontains(var.image, "@sha256:") || can(regex(":[A-Za-z0-9_][A-Za-z0-9_.-]*$", var.image)))
    error_message = "image must name a version tag or a digest, not latest: a new task would otherwise start whatever was pushed last."
  }
}

variable "vpc_id" {
  description = "VPC to deploy into."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnets for the task, the load balancer and the EFS mount targets. At least two, in different Availability Zones."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "private_subnet_ids needs at least two subnets: an Application Load Balancer requires two Availability Zones."
  }
}

variable "allowed_cidr_blocks" {
  description = "IPv4 ranges that may reach the load balancer."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.allowed_cidr_blocks : can(cidrnetmask(c)) && c != "0.0.0.0/0"])
    error_message = "allowed_cidr_blocks must be valid IPv4 ranges and must not include 0.0.0.0/0: name the networks that need the database."
  }
}

variable "allowed_security_group_ids" {
  description = "Security groups whose members may reach the load balancer."
  type        = list(string)
  default     = []
}

variable "certificate_arn" {
  description = "ACM certificate for an HTTPS listener on port 443. When null the listener is HTTP on port 80 and the bearer token crosses the VPC unencrypted."
  type        = string
  default     = null
}

variable "create_cluster" {
  description = "Create an ECS cluster for the service. Set to false and give cluster_arn to use an existing one."
  type        = bool
  default     = true

  validation {
    condition     = var.create_cluster || var.cluster_arn != null
    error_message = "cluster_arn is required when create_cluster is false."
  }
}

variable "cluster_arn" {
  description = "Existing ECS cluster to run in, when create_cluster is false."
  type        = string
  default     = null
}

variable "create_token_secret" {
  description = "Create a Secrets Manager secret and generate the bearer token, without storing the value in the state. Set to false and give token_secret_arn to use an existing secret."
  type        = bool
  default     = true

  validation {
    condition     = var.create_token_secret || var.token_secret_arn != null
    error_message = "token_secret_arn is required when create_token_secret is false."
  }
}

variable "token_secret_arn" {
  description = "Existing Secrets Manager secret whose plain-text value is the bearer token, when create_token_secret is false. It must be encrypted with the AWS-managed key or with kms_key_arn, or the task cannot read it."
  type        = string
  default     = null
}

variable "token_version" {
  description = "Increase to replace the generated token. Ignored when create_token_secret is false. The running task keeps the old token until the service is redeployed."
  type        = number
  default     = 1

  validation {
    condition     = var.token_version >= 1 && floor(var.token_version) == var.token_version
    error_message = "token_version must be a whole number, 1 or greater."
  }
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key for the file system and the token secret. When null both use the AWS-managed keys. The key policy must let the account's IAM policies grant use of the key."
  type        = string
  default     = null
}

variable "desired_count" {
  description = "1 to run the server, 0 to stop it and keep the data. The engine allows one process per database, so no other value is accepted."
  type        = number
  default     = 1

  validation {
    condition     = contains([0, 1], var.desired_count)
    error_message = "desired_count must be 0 or 1: two tasks on one database corrupt it."
  }
}

variable "cpu" {
  description = "Task CPU units. The engine uses one core."
  type        = number
  default     = 512
}

variable "memory" {
  description = "Task memory in MiB. Must be a size Fargate offers for the chosen cpu."
  type        = number
  default     = 1024
}

variable "cpu_architecture" {
  description = "ARM64 or X86_64. The image must have a variant for it."
  type        = string
  default     = "ARM64"

  validation {
    condition     = contains(["ARM64", "X86_64"], var.cpu_architecture)
    error_message = "cpu_architecture must be ARM64 or X86_64."
  }
}

variable "max_rows" {
  description = "Largest result a statement may return. The server builds a whole response in memory before sending it, so choose this and memory together."
  type        = number
  default     = 100000

  validation {
    condition     = var.max_rows >= 1 && floor(var.max_rows) == var.max_rows
    error_message = "max_rows must be a whole number, 1 or greater."
  }
}

variable "break_stale_lock" {
  description = "Take over the lock of a task that was killed. The new task first waits until the old one has stopped marking itself alive for 30 seconds; see the README."
  type        = bool
  default     = true
}

variable "idle_timeout_seconds" {
  description = "Seconds the load balancer waits for a response before it gives up. A statement that runs longer fails with 504 at the client and still runs to completion on the server."
  type        = number
  default     = 60

  validation {
    condition     = var.idle_timeout_seconds >= 1 && var.idle_timeout_seconds <= 4000
    error_message = "idle_timeout_seconds must be between 1 and 4000."
  }
}

variable "health_check_unhealthy_threshold" {
  description = "Consecutive failed health checks, 30 seconds apart, before the task is replaced. The server answers one request at a time, so a statement that runs for this many checks gets its task stopped."
  type        = number
  default     = 5

  validation {
    condition     = var.health_check_unhealthy_threshold >= 2 && var.health_check_unhealthy_threshold <= 10
    error_message = "health_check_unhealthy_threshold must be between 2 and 10."
  }
}

variable "log_retention_days" {
  description = "Days to keep the server's log in CloudWatch."
  type        = number
  default     = 30
}

variable "enable_backups" {
  description = "Let AWS Backup take its automatic daily backups of the file system."
  type        = bool
  default     = true
}

variable "container_insights" {
  description = "Container Insights setting for a cluster the module creates: enabled, enhanced or disabled."
  type        = string
  default     = "enabled"

  validation {
    condition     = contains(["enabled", "enhanced", "disabled"], var.container_insights)
    error_message = "container_insights must be enabled, enhanced or disabled."
  }
}

variable "tags" {
  description = "Tags for every resource, in addition to the provider's default_tags."
  type        = map(string)
  default     = {}
}
