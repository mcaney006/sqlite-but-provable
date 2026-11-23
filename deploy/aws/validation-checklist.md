# Validation checklist

State on 2026-11-22. Nothing here was applied to an AWS account.

| Check | Result |
|---|---|
| `terraform fmt -check -recursive deploy/aws` | Passes |
| `terraform validate` in `deploy/aws` and `deploy/aws/examples/basic` (Terraform 1.16.4, AWS provider 6.73.0, random provider 3.9.1) | Passes |
| Provider versions looked up on the Terraform Registry before pinning | `aws` 6.73.0 (2026-11-11), `random` 3.9.1 (2026-09-11) |
| Capacity model | Fargate launch type. No capacity provider strategy, no Fargate Spot. |
| `launch_type` and `capacity_provider_strategy` on the same service | Not present |
| awslogs `mode` set explicitly | `non-blocking`, 25 MiB buffer |
| Execution role and task role are separate | Yes |
| Trust policies | `aws:SourceAccount` and the account-wide `aws:SourceArn` wildcard; no cluster-scoped ARN |
| Deployment | Rolling, circuit breaker with rollback; no CodeDeploy |
| App Mesh | Not used |
| Fargate-excluded task parameters | None |
| `readonlyRootFilesystem` with ECS Exec | Read-only root; ECS Exec off |
| Image tag | `:latest` rejected by a variable validation |
| `count` and `for_each` on values unknown until apply | None: creation is switched by `create_cluster` and `create_token_secret`, and subnet, CIDR and security group lists are keyed by position |
| Two tasks on one database | Not prevented by ECS alone (`maximumPercent` counts running and pending tasks only, checked against the ECS API reference on 2026-11-22); the image's entry point makes a new task wait for the old one's heartbeat to stop |
| Secrets in `environment` | None; the token is in `secrets` |
| Token value in the state | No: ephemeral `random_password` and `secret_string_wo` |
| Application Auto Scaling | Not applicable: the service must never exceed one task |
| VPC endpoints | Not created; the README lists the ones a subnet without NAT needs |
| `terraform plan` or `apply` against an account | Not run |

## Deviations from the usual defaults

| Default | Here | Reason |
|---|---|---|
| Base the service on `terraform-aws-modules/ecs` | Plain resources | The deployment settings that keep one writer are the point of the module and are easier to audit in the open |
| Capacity provider strategy | `launch_type = "FARGATE"` | Works in an existing cluster whether or not it has capacity providers attached |
| `availability_zone_rebalancing = "ENABLED"` | `DISABLED` | Needs a maximum above 100 percent, which would allow two writers |
| `providers.tf` and `configs/backend.hcl` | Absent | This is a reusable module; the provider and backend belong to the root that calls it. `examples/basic` has the provider. |
| Autoscaling and a minimum of two tasks | One task | The engine allows one process per database |
