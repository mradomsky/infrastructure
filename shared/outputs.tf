output "ec2_instance_id" {
  description = "Shared EC2 instance ID"
  value       = aws_instance.shared_ec2.id
}

output "ec2_instance_ip" {
  description = "Public Elastic IP for shared EC2 instance"
  value       = aws_eip.shared_ec2.public_ip
}

output "ec2_security_group_id" {
  description = "Security group attached to the shared EC2 instance"
  value       = aws_security_group.shared_ec2.id
}

output "ec2_role_name" {
  description = "IAM role assumed by the shared EC2 instance, for cross-stack SSM parameter grants"
  value       = aws_iam_role.shared_ec2.name
}

output "alerts_topic_arn" {
  description = "SNS topic for shared infrastructure CloudWatch alarms"
  value       = aws_sns_topic.alerts.arn
}
