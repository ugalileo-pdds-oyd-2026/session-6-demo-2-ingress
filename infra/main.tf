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
