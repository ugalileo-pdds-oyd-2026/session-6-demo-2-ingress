output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets"
  value       = aws_subnet.private[*].id
}

output "web_sg_id" {
  description = "ID of the web (ALB-facing) security group — allows 80/443 from internet"
  value       = aws_security_group.web.id
}

output "app_sg_id" {
  description = "ID of the app security group — allows 8080 from the web security group"
  value       = aws_security_group.app.id
}
