output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer — the public endpoint for the service"
  value       = module.compute_ecs.alb_dns_name
}
