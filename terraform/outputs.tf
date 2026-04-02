output "ecr_backend_url" {
  description = "ECR repository URL for backend"
  value       = aws_ecr_repository.backend_repo.repository_url
}

output "ecr_frontend_url" {
  description = "ECR repository URL for frontend"
  value       = aws_ecr_repository.frontend_repo.repository_url
}

output "server_public_ip" {
  description = "Public IP of the EC2 instance"
  value       = aws_eip.lb.public_ip
}

output "ssh_command" {
  description = "SSH command to connect to the server"
  value       = "ssh -i gestione-spese-key.pem ec2-user@${aws_eip.lb.public_ip}"
}

output "app_url_http" {
  description = "Application URL (HTTP)"
  value       = "http://${aws_eip.lb.public_ip}"
}

output "aws_account_id" {
  description = "AWS Account ID (for ECR login)"
  value       = data.aws_caller_identity.current.account_id
}

# Data source to get AWS account ID
data "aws_caller_identity" "current" {}
