variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "eu-north-1"
}

variable "github_memory_repo" {
  description = "SSH URL of the private openclaw-memory GitHub repo"
  type        = string
}

variable "github_infra_repo" {
  description = "SSH URL of the private openclaw-aws infra repo (read-only reference for OpenClaw self-inspection)"
  type        = string
}
