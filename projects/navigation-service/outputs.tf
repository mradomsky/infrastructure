output "cluster_name" {
  description = "ECS cluster name."
  value       = module.navigation_service.cluster_name
}

output "service_name" {
  description = "ECS service name."
  value       = module.navigation_service.service_name
}

output "efs_file_system_id" {
  description = "EFS file system ID backing the SQLite volume."
  value       = module.navigation_service.efs_file_system_id
}

output "task_security_group_id" {
  description = "Task security group ID. Add as ingress source in ALB or peer services."
  value       = module.navigation_service.task_security_group_id
}

output "log_group_name" {
  description = "CloudWatch log group for ECS task logs."
  value       = module.navigation_service.log_group_name
}

output "sqlite_db_path" {
  description = "Full path to the SQLite file inside the container. Set SQLITE_DB_PATH to this value in Spring Boot config."
  value       = "/data/${var.sqlite_db_filename}"
}
