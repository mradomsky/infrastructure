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
