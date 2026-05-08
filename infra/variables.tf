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