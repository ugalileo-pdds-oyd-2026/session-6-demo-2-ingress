output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer — the public endpoint for the service"
  value       = aws_lb.this.dns_name
}

output "target_group_arn" {
  description = "ARN of the ALB target group — passed to the compute module for ECS service registration"
  value       = aws_lb_target_group.this.arn
}

output "alb_arn" {
  description = "ARN of the Application Load Balancer"
  value       = aws_lb.this.arn
}

output "alb_sg_id" {
  description = "Security group ID of the ALB — passed to compute_ecs to allow ingress on port 8080"
  value       = aws_security_group.alb.id
}
