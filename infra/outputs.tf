output "static_ip" {
  description = "Static public IP address of the Lightsail instance"
  value       = aws_lightsail_static_ip.openclaw.ip_address
}

output "ssm_role_arn" {
  description = "ARN of the SSM hybrid activation IAM role"
  value       = aws_iam_role.ssm_hybrid.arn
}

output "ssm_activation_id" {
  description = "SSM hybrid activation ID (needed during bootstrap)"
  value       = aws_ssm_activation.openclaw.id
}

output "openclaw_iam_user" {
  description = "IAM user name for OpenClaw agent credentials"
  value       = aws_iam_user.openclaw.name
}

# After apply, find the managed instance ID with:
# aws ssm describe-instance-information --query 'InstanceInformationList[*].InstanceId'
