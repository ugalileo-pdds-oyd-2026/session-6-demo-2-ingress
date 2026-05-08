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
