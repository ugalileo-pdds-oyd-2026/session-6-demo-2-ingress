output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer — the public endpoint for the service"
  value       = aws_lb.this.dns_name
}