variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-1"
}

variable "project_name" {
  description = "Project name"
  type        = string
  default     = "copilot-metrics-viewer"
}

variable "image_tag" {
  description = "Docker image tag"
  type        = string
  default     = "latest"
}

variable "environment_variables" {
  description = "Environment variables for Lambda"
  type        = map(string)
  default     = {}
}

variable "github_repository" {
  description = "GitHub repository in format 'owner/repo'"
  type        = string
}

variable "ecr_lifecycle_untagged_count" {
  description = "Number of untagged images to keep in ECR"
  type        = number
  default     = 3
}

variable "cloudwatch_logs_retention_days" {
  description = "CloudWatch Logs retention period in days"
  type        = number
  default     = 7

  validation {
    condition = contains([
      1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653
    ], var.cloudwatch_logs_retention_days)
    error_message = "CloudWatch Logs retention must be one of: 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653 days."
  }
}

variable "enable_cloudfront" {
  description = "Enable CloudFront distribution"
  type        = bool
  default     = false
}

variable "enable_waf" {
  description = "Enable WAF (requires CloudFront)"
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_waf || var.enable_cloudfront
    error_message = "WAF requires CloudFront to be enabled. Set enable_cloudfront = true when using enable_waf = true."
  }
}

variable "allowed_ip_addresses" {
  description = "List of additional allowed IP addresses for WAF (CIDR format). GitHub IPs are automatically included."
  type        = list(string)
  default     = []
}

variable "use_iam_auth" {
  description = "Use IAM authentication for Lambda Function URL (most secure, requires CloudFront)"
  type        = bool
  default     = false

  validation {
    condition     = !var.use_iam_auth || var.enable_cloudfront
    error_message = "IAM authentication requires CloudFront to be enabled. Set enable_cloudfront = true when using use_iam_auth = true."
  }
}

variable "github_ip_ranges" {
  description = "GitHub IP ranges for OAuth authentication (automatically included in WAF)"
  type        = list(string)
  default = [
    "140.82.112.0/20",
    "143.55.64.0/20",
    "185.199.108.0/22",
    "192.30.252.0/22",
    "20.201.28.151/32",
    "20.205.243.166/32",
    "20.248.137.48/32",
    "20.207.73.82/32",
    "20.27.177.113/32",
    "20.200.245.247/32",
    "20.233.54.53/32",
    "20.201.28.152/32",
    "20.205.243.160/32",
    "20.248.137.50/32",
    "20.207.73.83/32",
    "20.27.177.118/32",
    "20.200.245.248/32"
  ]
}
