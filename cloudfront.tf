# CloudFront Distribution
resource "aws_cloudfront_distribution" "main" {
  count = var.enable_cloudfront ? 1 : 0

  origin {
    domain_name = replace(aws_lambda_function_url.app.function_url, "https://", "")
    origin_id   = "lambda-origin"

    custom_origin_config {
      http_port              = 443
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    # Custom header for secret-based auth (when not using IAM)
    dynamic "custom_header" {
      for_each = var.use_iam_auth ? [] : [1]
      content {
        name  = "x-cloudfront-secret"
        value = random_password.cloudfront_secret[0].result
      }
    }

    # Origin Access Control for IAM auth
    origin_access_control_id = var.use_iam_auth ? aws_cloudfront_origin_access_control.lambda[0].id : null
  }

  enabled = true

  default_cache_behavior {
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "lambda-origin"
    compress               = true
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = true
      headers      = ["*"]
      cookies {
        forward = "all"
      }
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  web_acl_id = var.enable_waf ? aws_wafv2_web_acl.main[0].arn : null

  tags = {
    Name = "${var.project_name}-cloudfront"
  }
}

# Origin Access Control for IAM authentication
resource "aws_cloudfront_origin_access_control" "lambda" {
  count                             = var.use_iam_auth ? 1 : 0
  name                              = "${var.project_name}-lambda-oac"
  origin_access_control_origin_type = "lambda"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# IAM role for CloudFront to invoke Lambda
resource "aws_iam_role" "cloudfront_lambda_invoke" {
  count = var.use_iam_auth ? 1 : 0
  name  = "${var.project_name}-cloudfront-lambda-invoke"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "cloudfront.amazonaws.com"
      }
    }]
  })

  tags = {
    Name = "${var.project_name}-cloudfront-lambda-invoke"
  }
}

# IAM policy for CloudFront to invoke Lambda Function URL
resource "aws_iam_role_policy" "cloudfront_lambda_invoke" {
  count = var.use_iam_auth ? 1 : 0
  role  = aws_iam_role.cloudfront_lambda_invoke[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunctionUrl"
      Resource = aws_lambda_function.app.arn
    }]
  })
}

# Lambda permission for CloudFront (IAM auth)
resource "aws_lambda_permission" "cloudfront_invoke" {
  count         = var.use_iam_auth ? 1 : 0
  statement_id  = "AllowCloudFrontInvoke"
  action        = "lambda:InvokeFunctionUrl"
  function_name = aws_lambda_function.app.function_name
  principal     = "cloudfront.amazonaws.com"
  source_arn    = aws_cloudfront_distribution.main[0].arn
}

# Random secret for CloudFront header verification (only for custom header auth)
resource "random_password" "cloudfront_secret" {
  count   = var.enable_cloudfront && !var.use_iam_auth ? 1 : 0
  length  = 32
  special = true
}

# WAF Web ACL
resource "aws_wafv2_web_acl" "main" {
  count = var.enable_waf ? 1 : 0
  name  = "${var.project_name}-waf"
  scope = "CLOUDFRONT"

  default_action {
    block {}
  }

  # IP whitelist rule (always includes GitHub IPs)
  rule {
    name     = "IPWhitelistRule"
    priority = 1

    override_action {
      none {}
    }

    statement {
      ip_set_reference_statement {
        arn = aws_wafv2_ip_set.allowed_ips[0].arn
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "IPWhitelistRule"
      sampled_requests_enabled   = true
    }

    action {
      allow {}
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project_name}-waf"
    sampled_requests_enabled   = true
  }

  tags = {
    Name = "${var.project_name}-waf"
  }
}

# IP Set for allowed addresses (includes GitHub IPs)
resource "aws_wafv2_ip_set" "allowed_ips" {
  count              = var.enable_waf ? 1 : 0
  name               = "${var.project_name}-allowed-ips"
  scope              = "CLOUDFRONT"
  ip_address_version = "IPV4"
  addresses = concat(
    var.allowed_ip_addresses,
    var.github_ip_ranges
  )

  tags = {
    Name = "${var.project_name}-allowed-ips"
  }
}

# Update Lambda environment variables to include CloudFront secret
resource "aws_lambda_function" "app_with_cloudfront" {
  count = var.enable_cloudfront ? 1 : 0

  # This is a workaround to update the existing Lambda function
  # In practice, you'd modify the main Lambda resource
  depends_on = [aws_lambda_function.app]

  lifecycle {
    ignore_changes = all
  }
}

# Add CloudFront secret to Lambda environment
locals {
  cloudfront_env_vars = var.enable_cloudfront ? {
    CLOUDFRONT_SECRET = random_password.cloudfront_secret[0].result
  } : {}

  combined_env_vars = merge(var.environment_variables, local.cloudfront_env_vars)
}
