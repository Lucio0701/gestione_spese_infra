variable "aws_region" {
  description = "AWS Region"
  default     = "eu-south-1" # Milan region
}

variable "db_username" {
  description = "Database username"
  default     = "expense_user"
}

variable "db_password" {
  description = "Database password"
  sensitive   = true
}

variable "domain_name" {
  description = "Domain name for the application (optional, for HTTPS)"
  default     = ""
}
