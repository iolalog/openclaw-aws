variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "eu-north-1"
}

variable "openrouter_api_key" {
  description = "OpenRouter API key for LLM access"
  type        = string
  sensitive   = true
}

variable "slack_bot_token" {
  description = "Slack bot token (xoxb-...)"
  type        = string
  sensitive   = true
}

variable "slack_app_token" {
  description = "Slack app-level token for Socket Mode (xapp-...)"
  type        = string
  sensitive   = true
}

variable "github_memory_repo" {
  description = "SSH URL of the private openclaw-memory GitHub repo"
  type        = string
}
