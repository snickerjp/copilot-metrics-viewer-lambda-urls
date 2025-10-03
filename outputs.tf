output "function_url" {
  description = "Lambda Function URL (only shown when CloudFront is disabled)"
  value       = var.enable_cloudfront ? null : aws_lambda_function_url.app.function_url
}

output "function_name" {
  description = "Lambda function name"
  value       = aws_lambda_function.app.function_name
}

output "function_arn" {
  description = "Lambda function ARN"
  value       = aws_lambda_function.app.arn
}

output "github_actions_role_arn" {
  description = "ARN of the GitHub Actions IAM role"
  value       = aws_iam_role.github_actions.arn
}

output "cloudfront_url" {
  description = "CloudFront distribution URL"
  value       = var.enable_cloudfront ? "https://${aws_cloudfront_distribution.main[0].domain_name}" : null
}

output "cloudfront_secret" {
  description = "CloudFront secret for header verification (only for custom header auth)"
  value       = var.enable_cloudfront && !var.use_iam_auth ? random_password.cloudfront_secret[0].result : null
  sensitive   = true
}
