# Session 6 — Demo 2: Ingress Module + WAF

Extend an existing ECS Fargate project with a reusable `modules/network/` module and a dedicated `modules/ingress/` module that owns the ALB, listener, target group, and WAF — eliminating hardcoded VPC IDs and decoupling ingress routing from the compute workload.

> **Forked from:** [`ugalileo-pdds-oyd-2026/session-3-demo-3-ecs`](https://github.com/ugalileo-pdds-oyd-2026/session-3-demo-3-ecs) — the Session 3 ECS Fargate module that this demo extends.

## What students learn

- Why hardcoded `vpc_id` and `subnet_ids` in `dev.tfvars` cause plans to fail when the code is cloned to a different AWS account
- Why placing the ALB inside the compute module couples two separate concerns and how extracting it into an ingress module fixes that
- How to wire a two-tier security group stack (`web` → `app`) so the network module owns all access-control decisions in one place
- How module outputs become the shared contract between modules — `module.network.*` replaces every hardcoded network reference
- How `aws_wafv2_web_acl_association` attaches a rate-based WAF rule to an ALB with no changes to application code
- Why `scope = "REGIONAL"` is required for ALBs (versus `CLOUDFRONT` for CloudFront distributions)
- How `terraform init -backend=false` validates a full configuration in CI without AWS credentials or a real backend

## Project structure

```
.
├── app/
│   ├── go.mod
│   ├── go.sum
│   ├── main.go          # routes /health and /echo
│   ├── server.go        # HTTP entrypoint (build tag: !lambda)
│   ├── lambda.go        # excluded from Docker build via build tag
│   └── Dockerfile       # multi-stage, linux/arm64
└── infra/
    ├── provider.tf
    ├── variables.tf      # CIDRs, AZs, and compute vars — no hardcoded IDs
    ├── outputs.tf        # alb_dns_name sourced from module.ingress
    ├── main.tf           # wires network → ingress → compute_ecs
    ├── envs/dev/dev.tfvars
    └── modules/
        ├── network/
        │   ├── variables.tf   # vpc_cidr, subnet CIDRs, availability_zones, environment
        │   ├── main.tf        # VPC, subnets, IGW, NAT GW, route tables, web/app SGs
        │   └── outputs.tf     # vpc_id, public_subnet_ids, private_subnet_ids, web_sg_id, app_sg_id
        ├── ingress/
        │   ├── variables.tf   # environment, name, vpc_id, public_subnet_ids, app_sg_id
        │   ├── main.tf        # ALB SG, ALB, target group, listener, WAF ACL, WAF association
        │   └── outputs.tf     # alb_dns_name, target_group_arn, alb_arn, alb_sg_id
        └── compute_ecs/
            ├── variables.tf   # accepts target_group_arn and alb_sg_id instead of creating its own ALB
            ├── main.tf        # IAM roles, task SG, ECS cluster, task definition, ECS service
            └── outputs.tf
```

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.6
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) configured with credentials that can create ECS, ALB, WAF, IAM, and VPC resources

## Demo workflow

### 1. Explore the module structure

```bash
tree infra/
```

### 2. Review the hardcoded starting point

The source repo contained fixed AWS resource IDs in `dev.tfvars`:

```hcl
vpc_id     = "vpc-2e760856"                              # ⚠️ hardcoded
subnet_ids = ["subnet-a88843d0", "subnet-f927d2b3"]     # ⚠️ hardcoded
```

These IDs are account-specific. Anyone who forks this repo and deploys to a different AWS account gets a silent failure or deploys into the wrong VPC.

### 3. Review the network module

Open `infra/modules/network/main.tf`. The module provisions resources in this dependency order, which Terraform resolves automatically from the references:

1. `aws_vpc.this` — VPC with DNS support and DNS hostnames enabled
2. `aws_subnet.public[*]` and `aws_subnet.private[*]` — two subnet tiers, scaled by `count`
3. `aws_internet_gateway.this` — attached to the VPC for public egress
4. `aws_eip.nat` + `aws_nat_gateway.this` — NAT in `public[0]` for private subnet egress
5. `aws_route_table.public` / `aws_route_table.private` — default routes to IGW and NAT GW
6. `aws_security_group.web` / `aws_security_group.app` — two-tier SG stack; `app` ingress references only `web`

Open `infra/envs/dev/dev.tfvars`. The hardcoded IDs are gone — replaced with portable CIDR declarations:

```hcl
vpc_cidr             = "10.0.0.0/16"
public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24"]
private_subnet_cidrs = ["10.0.11.0/24", "10.0.12.0/24"]
availability_zones   = ["us-west-2a", "us-west-2b"]
```

### 4. Review the network module outputs

Open `infra/modules/network/outputs.tf`. Every downstream module consumes references from here — no account-specific IDs flow anywhere:

```hcl
output "vpc_id"              { value = aws_vpc.this.id }
output "public_subnet_ids"   { value = aws_subnet.public[*].id }
output "private_subnet_ids"  { value = aws_subnet.private[*].id }
output "web_sg_id"           { value = aws_security_group.web.id }
output "app_sg_id"           { value = aws_security_group.app.id }
```

### 5. Review the ingress module

Open `infra/modules/ingress/main.tf`. The module owns everything at the edge:

- `aws_security_group.alb` — port 80 open from `0.0.0.0/0`
- `aws_lb.this` — public ALB in `public_subnet_ids`
- `aws_lb_target_group.this` — port 8080, health check at `/health`
- `aws_lb_listener.http` — forwards traffic to the target group
- `aws_wafv2_web_acl.this` — rate-based rule, 2000 requests per 5-minute window per IP, action `block`
- `aws_wafv2_web_acl_association.this` — attaches the ACL to the ALB ARN

The WAF association is a separate resource so the same ACL can be attached to multiple ALBs, or swapped out without touching the ALB.

### 6. Review how the root module wires the three modules together

Open `infra/main.tf`:

```hcl
module "network" {
  source = "./modules/network"

  environment          = var.environment
  vpc_cidr             = var.vpc_cidr
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  availability_zones   = var.availability_zones
}

module "ingress" {
  source = "./modules/ingress"

  environment       = var.environment
  name              = var.name
  vpc_id            = module.network.vpc_id
  public_subnet_ids = module.network.public_subnet_ids
  app_sg_id         = module.network.app_sg_id
}

module "compute_ecs" {
  source = "./modules/compute_ecs"

  environment      = var.environment
  name             = var.name
  cpu              = var.cpu
  memory           = var.memory
  container_image  = var.container_image
  subnet_ids       = module.network.private_subnet_ids
  vpc_id           = module.network.vpc_id
  target_group_arn = module.ingress.target_group_arn
  alb_sg_id        = module.ingress.alb_sg_id
}
```

The dependency graph is `network → ingress → compute_ecs`. Terraform resolves this automatically — the value references create the edges, no explicit `depends_on` is needed.

### 7. Review the compute module changes

Open `infra/modules/compute_ecs/main.tf`. The four ALB resources (`aws_lb`, `aws_lb_target_group`, `aws_lb_listener`, `aws_security_group.alb`) have been removed. The module now receives two new inputs:

- `target_group_arn` — passed directly to the ECS service `load_balancer` block
- `alb_sg_id` — used as the ingress source on the task security group (port 8080)

The ECS service also sets `assign_public_ip = false` — tasks now run in private subnets and are only reachable through the ALB.

### 8. Validate

```bash
cd infra/
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
```

Expected output:

```
Success! The configuration is valid.
```

Confirm the output chain mentally:
- `aws_lb.this.dns_name` → `module.ingress.alb_dns_name` → root `output "alb_dns_name"`
- `aws_lb_target_group.this.arn` → `module.ingress.target_group_arn` → `module.compute_ecs.target_group_arn` → `aws_ecs_service.this.load_balancer[0].target_group_arn`

### 9. Deploy

```bash
terraform init
terraform plan -var-file=envs/dev/dev.tfvars
terraform apply -var-file=envs/dev/dev.tfvars
```

ECS service stabilisation (ALB health check passing) takes approximately 3 minutes after apply completes.

```bash
aws ecs describe-services \
  --cluster demo-ecs-dev --services demo-ecs-dev \
  --query 'services[0].{Status:status,Running:runningCount}'
```

### 10. Verify

```bash
ALB_DNS=$(terraform output -raw alb_dns_name)

curl http://${ALB_DNS}/health
```

Expected output:

```json
{"compute":"ecs","status":"ok"}
```

```bash
curl -X POST http://${ALB_DNS}/echo \
  -H "Content-Type: application/json" -d '{"message":"hello"}'
```

Expected output:

```json
{"compute":"ecs","message":"hello"}
```

### 11. Clean up

```bash
terraform destroy -var-file=envs/dev/dev.tfvars
```

## Expected outcomes

By the end of this demo, students should be able to:

1. Explain why hardcoded VPC and subnet IDs in `dev.tfvars` break plans when the code is cloned to a different AWS account
2. Build a network module that creates a VPC with public and private subnet tiers using `count`, so adding an AZ requires only a new CIDR entry in `dev.tfvars`
3. Wire a two-tier security group stack where the app tier accepts traffic only from the web (ALB) security group
4. Extract an ALB from a compute module into a dedicated ingress module, and pass `target_group_arn` and `alb_sg_id` back to the compute module as plain inputs
5. Attach a WAF Web ACL to an ALB using `aws_wafv2_web_acl_association`, and explain why `scope = "REGIONAL"` is required for ALBs
6. Use `terraform init -backend=false` to validate a configuration without AWS credentials or a real backend
