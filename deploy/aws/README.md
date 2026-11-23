# IdrisQL on AWS

A Terraform module that runs the IdrisQL HTTP server (`docs/SERVER.md`) as
one Amazon ECS task on Fargate, with the database on Amazon EFS and an
internal Application Load Balancer in front.

This module has been formatted and validated (`terraform fmt`, `terraform
validate`, and the checks listed in `validation-checklist.md`). It has not
been applied to an AWS account. Run `terraform plan` and read it before the
first apply.

## What it creates

| Resource | Purpose |
|---|---|
| ECS cluster (unless `cluster_arn` is given), task definition, service | One Fargate task running the container image |
| EFS file system, access point, one mount target per subnet | The database directory, encrypted at rest and in transit |
| Internal Application Load Balancer, target group, listener | The only way in; HTTPS when `certificate_arn` is set |
| Three security groups | Clients to load balancer, load balancer to task, task to file system |
| Two IAM roles | Execution role (pull image, write log, read token) and task role (mount the file system) |
| Secrets Manager secret (unless `token_secret_arn` is given) | The bearer token |
| CloudWatch log group | The server's standard error |

It does not create a VPC, subnets, NAT gateways, VPC endpoints or DNS
records.

## Requirements

| Requirement | Detail |
|---|---|
| Terraform | 1.11 or later, for write-only arguments |
| AWS provider | 6.73 or later, below 7 |
| Network | A VPC with two or more private subnets in different Availability Zones |
| Image pull | The task has no public address and the module passes no registry credentials. An image on `ghcr.io` needs a NAT gateway and a public package. An image copied to Amazon ECR needs either a NAT gateway or the `ecr.api`, `ecr.dkr`, `logs` and `secretsmanager` interface endpoints plus the `s3` gateway endpoint. |
| Image tag | A version tag or a digest. `:latest` is rejected. |

## Use

```hcl
module "idrisql" {
  source = "github.com/mcaney006/sqlite-but-provable//deploy/aws"

  name                = "idrisql-dev"
  image               = "ghcr.io/mcaney006/sqlite-but-provable:sha-<commit>"
  vpc_id              = "vpc-..."
  private_subnet_ids  = ["subnet-...", "subnet-..."]
  allowed_cidr_blocks = ["10.0.0.0/16"]
}
```

`examples/basic` is a complete root module with the provider block.

After an apply, from a machine in an allowed network:

```sh
TOKEN="$(aws secretsmanager get-secret-value --secret-id "$(terraform output -raw token_secret_arn)" \
  --query SecretString --output text)"
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  --data-binary "SELECT 1 + 1 AS two" "$(terraform output -raw endpoint)/query"
```

## Inputs

| Name | Default | Meaning |
|---|---|---|
| `name` | required | Name for the service and its resources; 3 to 24 characters |
| `image` | required | Container image with a tag or digest |
| `vpc_id` | required | VPC to deploy into |
| `private_subnet_ids` | required | Two or more private subnets |
| `allowed_cidr_blocks` | `[]` | IPv4 ranges that may reach the load balancer. `0.0.0.0/0` is rejected. |
| `allowed_security_group_ids` | `[]` | Security groups that may reach the load balancer |
| `certificate_arn` | `null` | ACM certificate. When null the listener is HTTP on port 80. |
| `create_cluster`, `cluster_arn` | `true`, `null` | Set to `false` and an ARN to use an existing ECS cluster |
| `create_token_secret`, `token_secret_arn` | `true`, `null` | Set to `false` and an ARN to use an existing secret whose plain-text value is the token |
| `token_version` | `1` | Increase to generate a new token |
| `kms_key_arn` | `null` | Customer-managed key for the file system and the token secret |
| `desired_count` | `1` | 1 to run, 0 to stop and keep the data |
| `cpu`, `memory` | `512`, `1024` | Fargate task size |
| `cpu_architecture` | `ARM64` | `ARM64` or `X86_64` |
| `max_rows` | `100000` | Most rows one response may hold |
| `break_stale_lock` | `true` | Take over the lock of a task that has stopped marking itself alive |
| `idle_timeout_seconds` | `60` | Load balancer's wait for a response |
| `health_check_unhealthy_threshold` | `5` | Failed checks before the task is replaced |
| `log_retention_days` | `30` | CloudWatch retention |
| `enable_backups` | `true` | AWS Backup's automatic backups of the file system |
| `container_insights` | `enabled` | For a cluster the module creates |
| `tags` | `{}` | Added to every resource |

Outputs: `endpoint`, `load_balancer_dns_name`, `load_balancer_zone_id`,
`load_balancer_security_group_id`, `token_secret_arn`, `cluster_arn`,
`service_name`, `file_system_id`, `log_group_name`.

## One writer

The engine allows one process per database. A second process that opens
the same directory with the lock overridden corrupts it
(`docs/TRANSACTIONS.md`). Two layers keep that from happening.

The service never asks for a second task:

| Setting | Value | Reason |
|---|---|---|
| `desired_count` | 0 or 1, checked by a validation | There is nothing for a second task to do |
| `deployment_minimum_healthy_percent`, `deployment_maximum_percent` | 0, 100 | ECS may not have two tasks running or pending |
| `availability_zone_rebalancing` | `DISABLED` | Rebalancing starts the replacement first |
| Capacity | Fargate, not Fargate Spot; no Application Auto Scaling | Spot interruptions and scaling both replace or add tasks |

That is not enough by itself. The maximum counts tasks that are running or
pending. A task that ECS has told to stop is neither, and it can go on
running for up to its 120-second stop timeout while it finishes a
statement. ECS can start the replacement during that time.

So the image's entry point makes the replacement wait
(`docs/SERVER.md`, "Signals and stopping"). The running task touches a
file beside the database every two seconds. With `break_stale_lock`, a new
task that finds the lock held waits until that file has gone untouched for
30 seconds and only then takes the lock over. Without `break_stale_lock`
a new task that finds a lock exits, and after a killed task someone has to
remove the lock by hand.

What remains unguarded: two new tasks that both find the same dead holder
at the same moment would both take the lock, and the heartbeat detects a
dead holder without fencing a live one that cannot write it. The service
settings above do not start two tasks together, and a task that cannot
write its heartbeat for about ten seconds kills its own server.

A storage failure that leaves the engine unusable makes the server exit
with status 1. ECS then starts a new task, which runs recovery.

The cost of all this is a gap in service on every deployment and every
task replacement: the old task stops, the new one waits, pulls the image
and mounts the file system. The gap has not been measured. The service's
health check grace period is 300 seconds to cover it.

## Durability on EFS

A commit is handed to the operating system and not forced to the device
(`docs/PLATFORM_CONSTRAINTS.md`). On Fargate that means:

| Event | Committed data |
|---|---|
| The task is stopped by a deployment or `desired_count = 0` | Kept. ECS sends SIGTERM, the entry point closes the database, and `stopTimeout` allows 120 seconds for it. |
| The server process is killed | Kept. Recovery replays the log at the next start. |
| The Fargate host fails, or the task is killed before the NFS client has written its cached pages | Recent commits may be lost, and the database may be left unreadable |

`enable_backups` is on by default for the last row. Restore is a manual
AWS Backup operation into a new file system.

The engine writes one 4 KiB file per page and the log beside it. On EFS
each of those writes crosses the network. Throughput on EFS has not been
measured; the figures in `docs/BENCHMARKS.md` are for a local SSD.

## Long statements

The server answers one request at a time, health checks included.

| Limit | Default | Effect |
|---|---|---|
| Load balancer idle timeout | 60 seconds | A statement that takes longer gets 504 at the client. The server finishes it anyway, so a write can be committed although the client saw an error. |
| Health check | Every 30 seconds, 10-second timeout, 5 failures | A statement that blocks the server for about two and a half minutes gets the task marked unhealthy and stopped. The statement still commits if it finishes within the 120-second stop timeout; after that the task is killed and the transaction is lost. |

Raise `idle_timeout_seconds` and `health_check_unhealthy_threshold`
together if statements need longer.

## Network and credentials

| Path | Control |
|---|---|
| Clients to load balancer | Internal load balancer; ingress only from `allowed_cidr_blocks` and `allowed_security_group_ids`, on the listener port |
| Load balancer to task | Task security group accepts port 5480 from the load balancer's security group only |
| Task to file system | Port 2049 to the mount targets; the file system policy allows only the task role, only through the access point, and denies unencrypted transport |
| Task to the internet | Port 443 outbound, for the image registry, CloudWatch Logs and Secrets Manager |

Without `certificate_arn` the bearer token crosses the VPC in clear text
between client and load balancer. Between load balancer and task it is
always HTTP.

With `certificate_arn`, the `endpoint` output is still the load balancer's
own name, which your certificate does not cover. Create a DNS alias to
`load_balancer_dns_name` in the certificate's domain and use that.

The generated token is a 48-character random string. Terraform creates it
as an ephemeral value and sends it to Secrets Manager through a write-only
argument, so it is in neither the plan nor the state. To replace it,
increase `token_version`, apply, and force a new deployment of the service
so the task reads the new value.

The container runs as uid 10001 with a read-only root file system and all
Linux capabilities dropped. ECS Exec is off.

## What is billed

An Application Load Balancer, one Fargate task, EFS storage and elastic
throughput, AWS Backup storage, one Secrets Manager secret, CloudWatch log
ingestion, Container Insights when enabled, and whatever the image pull
path needs (NAT gateway or interface endpoints). Use the AWS Pricing
Calculator for figures; none are given here.

## Removing it

`terraform destroy` deletes the file system and the database with it. Take
a backup first if the data matters. Setting `desired_count = 0` stops the
task and keeps everything else.
