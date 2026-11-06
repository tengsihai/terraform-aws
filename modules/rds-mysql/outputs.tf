output "instance_id" {
  description = "RDS instance identifier."
  value       = aws_db_instance.this.identifier
}

output "instance_arn" {
  description = "ARN of the RDS instance."
  value       = aws_db_instance.this.arn
}

output "endpoint" {
  description = "Host:port endpoint of the instance."
  value       = aws_db_instance.this.endpoint
}

output "address" {
  description = "Hostname of the instance, without the port."
  value       = aws_db_instance.this.address
}

output "port" {
  description = "TCP port the instance listens on."
  value       = aws_db_instance.this.port
}

output "database_name" {
  description = "Initial database created inside the instance."
  value       = aws_db_instance.this.db_name
}

output "security_group_id" {
  description = "Security group controlling access to the instance."
  value       = aws_security_group.this.id
}

output "master_user_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the master user credentials. The secret value is never exposed by Terraform."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}
