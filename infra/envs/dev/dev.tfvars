environment     = "dev"
name            = "demo-ecs"
cpu             = 256
memory          = 512
container_image = "439426070073.dkr.ecr.us-west-2.amazonaws.com/demo-ecs:latest"

vpc_cidr             = "10.0.0.0/16"
public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24"]
private_subnet_cidrs = ["10.0.11.0/24", "10.0.12.0/24"]
availability_zones   = ["us-west-2a", "us-west-2b"]
