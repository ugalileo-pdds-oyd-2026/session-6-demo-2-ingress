# Session 3 — Demo C: ECS Fargate + ALB Module

Deploy a containerised Go service on AWS ECS Fargate behind an Application Load Balancer, provisioned with a reusable Terraform module.

## What students learn

- How a multi-stage Dockerfile compiles a Go binary for `linux/arm64` inside Docker, without a local Go installation
- The difference between the ECS **execution role** (control plane: pulls images from ECR, writes logs to CloudWatch) and the **task role** (application: calls AWS services at runtime)
- Why `security_groups` inside `aws_security_group` is a list, and how that differs from `source_security_group_id` in `aws_security_group_rule`
- Why `runtime_platform { cpu_architecture = "ARM64" }` is required for Graviton Fargate — omitting it silently defaults to x86_64 and your arm64 image fails to start
- Why `depends_on = [aws_lb_listener.http]` must be declared explicitly on the ECS service — a dependency Terraform cannot infer from resource references alone
- How the same Go binary is reused across Lambda and ECS by switching the compute platform via an environment variable (`COMPUTE_TYPE`)

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
    ├── backend.tf        # S3 remote state + DynamoDB lock
    ├── variables.tf
    ├── outputs.tf
    ├── main.tf           # module call — fill this in
    ├── envs/dev/dev.tfvars
    └── modules/
        └── compute_ecs/
            ├── variables.tf   # fill this in
            ├── outputs.tf     # fill this in
            └── main.tf        # fill this in
```

The three files inside `modules/compute_ecs/` and the body of `infra/main.tf` are empty — you will write them during the demo.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.6
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) configured with credentials that can create ECS, ALB, IAM, and VPC resources

## Demo workflow

### 1. Review the application

Open `app/Dockerfile`. The binary is compiled inside Docker using a multi-stage build — no local Go toolchain is needed. The first stage produces an `arm64` binary; the second stage runs it on Alpine.

`server.go` carries a `//go:build !lambda` tag at the top. This build tag automatically excludes `lambda.go` during the Docker build — no `-tags` flag is needed.

### 2. Fill in `infra/envs/dev/dev.tfvars`

Replace the placeholder values with your own AWS account details:

```hcl
environment     = "dev"
name            = "demo-ecs"
cpu             = 256
memory          = 512
container_image = "<ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/demo-ecs:latest"
subnet_ids      = ["<SUBNET_A>", "<SUBNET_B>"]
vpc_id          = "<VPC_ID>"
```

Look up the values with:

```bash
# Default VPC
aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId'

# Two default subnets in different AZs
aws ec2 describe-subnets --filters Name=defaultForAz,Values=true --query 'Subnets[*].SubnetId'
```

### 3. Write `infra/modules/compute_ecs/variables.tf`

Declare the seven input variables the module accepts:

```hcl
variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
}

variable "name" {
  description = "Base name applied to all ECS and ALB resources"
  type        = string
}

variable "cpu" {
  description = "Fargate task CPU units (256, 512, 1024, 2048, 4096)"
  type        = number
  default     = 256
}

variable "memory" {
  description = "Fargate task memory in MB — must be compatible with cpu value"
  type        = number
  default     = 512
}

variable "container_image" {
  description = "Container image URI including tag (ECR or Docker Hub)"
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs for ALB and ECS tasks — minimum 2 across different AZs"
  type        = list(string)
}

variable "vpc_id" {
  description = "VPC ID where ALB and task security groups will be created"
  type        = string
}
```

### 4. Write `infra/modules/compute_ecs/main.tf`

Build the module resource by resource in this order.

**IAM roles** — two distinct roles, both with the ECS tasks principal:

```hcl
# Execution role: used by the ECS control plane to pull the image and write logs
resource "aws_iam_role" "execution" {
  name = "${var.name}-${var.environment}-execution-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Task role: assumed by the running container — add attachments when the app calls AWS services
resource "aws_iam_role" "task" {
  name = "${var.name}-${var.environment}-task-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}
```

**Security groups** — ALB open to the internet; tasks reachable only from the ALB:

```hcl
resource "aws_security_group" "alb" {
  name        = "${var.name}-${var.environment}-alb-sg"
  description = "Allow HTTP from internet to ALB"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "task" {
  name        = "${var.name}-${var.environment}-task-sg"
  description = "ALB security group access only"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
```

**ECS cluster and task definition** — note `runtime_platform` is required for Graviton:

```hcl
resource "aws_ecs_cluster" "this" {
  name = "${var.name}-${var.environment}"
}

resource "aws_ecs_task_definition" "this" {
  family                   = "${var.name}-${var.environment}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([{
    name         = var.name
    image        = var.container_image
    essential    = true
    portMappings = [{ containerPort = 8080, hostPort = 8080, protocol = "tcp" }]
    environment  = [{ name = "COMPUTE_TYPE", value = "ecs" }]
  }])
}
```

**ALB, target group, listener, and ECS service**:

```hcl
resource "aws_lb" "this" {
  name               = "${var.name}-${var.environment}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.subnet_ids
}

resource "aws_lb_target_group" "this" {
  name        = "${var.name}-${var.environment}-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

resource "aws_ecs_service" "this" {
  name            = "${var.name}-${var.environment}"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.this.arn
    container_name   = var.name
    container_port   = 8080
  }

  depends_on = [aws_lb_listener.http]
}
```

### 5. Write `infra/modules/compute_ecs/outputs.tf`

```hcl
output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer — the public endpoint for the service"
  value       = aws_lb.this.dns_name
}
```

### 6. Write `infra/main.tf`

```hcl
module "compute_ecs" {
  source = "./modules/compute_ecs"

  environment     = var.environment
  name            = var.name
  cpu             = var.cpu
  memory          = var.memory
  container_image = var.container_image
  subnet_ids      = var.subnet_ids
  vpc_id          = var.vpc_id
}
```

### 7. Deploy

```bash
cd infra/
terraform init
terraform plan -var-file=envs/dev/dev.tfvars
terraform apply -var-file=envs/dev/dev.tfvars
```

ECS service stabilisation (ALB health check passing) takes approximately 3 minutes after apply completes. Monitor service status while waiting:

```bash
aws ecs describe-services \
  --cluster demo-ecs-dev --services demo-ecs-dev \
  --query 'services[0].{Status:status,Running:runningCount}'
```

### 8. Verify

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

### 9. Clean up

```bash
terraform destroy -var-file=envs/dev/dev.tfvars
```

ECS service de-registration takes approximately 60 seconds.

## Expected outcomes

By the end of this demo, students should be able to:

1. Explain the difference between an ECS execution role and a task role, and describe the consequences of swapping them
2. Write a Terraform ECS Fargate task definition that targets Graviton (arm64) using `runtime_platform`
3. Restrict task network access so containers are only reachable through the ALB security group, not from the internet directly
4. Identify implicit dependency gaps in Terraform resource graphs and fix them with `depends_on`
5. Deploy a containerised application to ECS Fargate and verify it is healthy via the ALB endpoint
