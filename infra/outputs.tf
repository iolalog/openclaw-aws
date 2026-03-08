output "public_ip" {
  description = "Static public IP address of the EC2 instance"
  value       = aws_eip.openclaw.public_ip
}

output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.openclaw.id
}

output "instance_role_arn" {
  description = "ARN of the EC2 instance role"
  value       = aws_iam_role.openclaw.arn
}

# Connect via SSM Session Manager (no SSH needed):
# aws ssm start-session --target <instance_id>
