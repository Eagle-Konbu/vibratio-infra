variable "aws_region" {
  description = "AWS region for all regional resources."
  type        = string
  default     = "ap-northeast-1"
}

variable "project_name" {
  description = "Prefix for resource names."
  type        = string
  default     = "vibratio"
}

variable "log_retention_days" {
  description = "Retention period for CloudWatch Logs log groups."
  type        = number
  default     = 30
}

variable "batch_schedule_expression" {
  description = "EventBridge Scheduler expression for the daily batch."
  type        = string
  default     = "cron(0 6 * * ? *)"
}

variable "batch_schedule_timezone" {
  description = "Timezone used to evaluate batch_schedule_expression."
  type        = string
  default     = "Asia/Tokyo"
}

variable "batch_timeout_seconds" {
  description = "Timeout of the batch Lambda function. LLM and TTS calls can take several minutes."
  type        = number
  default     = 900
}

variable "batch_memory_size_mb" {
  description = "Memory size of the batch Lambda function."
  type        = number
  default     = 512
}

variable "batch_secret_names" {
  description = "Names of SecureString parameters created under /<project_name>/batch/ for external API credentials."
  type        = set(string)
  default     = ["llm-api-key", "tts-api-key", "discord-webhook-url"]
}
