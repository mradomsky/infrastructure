output "ec2_instance_id" {
  description = "Shared EC2 instance ID"
  value       = aws_instance.shared_ec2.id
}

output "ec2_instance_ip" {
  description = "Public IP when enabled, otherwise private IP"
  value       = var.associate_public_ip_address ? aws_eip.shared_ec2[0].public_ip : aws_instance.shared_ec2.private_ip
}

output "ec2_security_group_id" {
  description = "Security group attached to the shared EC2 instance"
  value       = aws_security_group.shared_ec2.id
}
