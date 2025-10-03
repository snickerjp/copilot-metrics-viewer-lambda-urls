# Lambda Function URL IP Restriction Implementation Guide

## Overview

This guide explains how to restrict access to Lambda Function URLs to specific IP addresses only.

### Allowed IP Ranges

1. **GitHub OAuth Callback**
   - `192.30.252.0/22`
   - `185.199.108.0/22`
   - `140.82.112.0/20`
   - `143.55.64.0/20`
   - Individual IPs via Azure (20.x.x.x, 4.x.x.x)

## Implementation Methods

### Method 1: CloudFront + AWS WAF (Recommended)

#### Architecture
```
User/GitHub → CloudFront → AWS WAF → Lambda Function URL
```

#### Benefits
- Flexible IP restrictions with WAF
- Performance improvement and cost reduction through CloudFront caching
- DDoS protection
- Easy SSL certificate management

#### Cost
- CloudFront: $0.085/GB (first 10TB)
- WAF: $5/month + $1/rule
- Total: ~$6-10/month

#### Terraform Implementation Example

```hcl
# CloudFront Distribution
resource "aws_cloudfront_distribution" "app" {
  enabled = true
  
  origin {
    domain_name = replace(aws_lambda_function_url.app.function_url, "https://", "")
    origin_id   = "lambda"
    
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }
  
  default_cache_behavior {
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "lambda"
    viewer_protocol_policy = "redirect-to-https"
    
    forwarded_values {
      query_string = true
      headers      = ["*"]
      cookies {
        forward = "all"
      }
    }
  }
  
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
  
  viewer_certificate {
    cloudfront_default_certificate = true
  }
  
  web_acl_id = aws_wafv2_web_acl.app.arn
}

# WAF Web ACL
resource "aws_wafv2_web_acl" "app" {
  name  = "copilot-metrics-viewer-waf"
  scope = "CLOUDFRONT"
  
  default_action {
    block {}
  }
  
  rule {
    name     = "AllowGitHubAndOffice"
    priority = 1
    
    action {
      allow {}
    }
    
    statement {
      ip_set_reference_statement {
        arn = aws_wafv2_ip_set.allowed_ips.arn
      }
    }
    
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AllowGitHubAndOffice"
      sampled_requests_enabled   = true
    }
  }
  
  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "copilot-metrics-viewer-waf"
    sampled_requests_enabled   = true
  }
}

# IP Set
resource "aws_wafv2_ip_set" "allowed_ips" {
  name               = "allowed-ips"
  scope              = "CLOUDFRONT"
  ip_address_version = "IPV4"
  
  addresses = [
    # GitHub
    "192.30.252.0/22",
    "185.199.108.0/22",
    "140.82.112.0/20",
    "143.55.64.0/20",
    "20.201.28.151/32",
    "20.205.243.166/32",
    "20.87.245.0/32",
    "4.237.22.38/32",
    "4.228.31.150/32",
    "20.207.73.82/32",
    "20.27.177.113/32",
    "20.200.245.247/32",
    "20.175.192.147/32",
    "20.233.83.145/32",
    "20.29.134.23/32",
    "20.199.39.232/32",
    "20.217.135.5/32",
    "4.225.11.194/32",
    "4.208.26.197/32",
    "20.26.156.215/32",
  ]
}
```

#### Deployment Steps

1. Add WAF and CloudFront resources
```bash
terraform apply
```

2. Get CloudFront domain name
```bash
terraform output cloudfront_domain
```

3. Update GitHub App Callback URL
   - `https://<cloudfront-domain>/api/auth/github`

### Method 2: API Gateway + Lambda

#### Architecture
```
User/GitHub → API Gateway (Resource Policy) → Lambda
```

#### Benefits
- Direct IP restriction using API Gateway resource policy
- Simpler configuration than CloudFront

#### Drawbacks
- Cannot use Lambda Function URL (requires different integration)
- Slightly higher cost ($3.50/million requests)

#### Terraform Implementation Example

```hcl
resource "aws_apigatewayv2_api" "app" {
  name          = "copilot-metrics-viewer"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id           = aws_apigatewayv2_api.app.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.app.invoke_arn
}

resource "aws_apigatewayv2_route" "default" {
  api_id    = aws_apigatewayv2_api.app.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.app.id
  name        = "$default"
  auto_deploy = true
}

# IP restriction with resource policy
resource "aws_api_gateway_rest_api_policy" "app" {
  rest_api_id = aws_apigatewayv2_api.app.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = "*"
        Action = "execute-api:Invoke"
        Resource = "*"
        Condition = {
          IpAddress = {
            "aws:SourceIp" = [
              "192.30.252.0/22",
              "185.199.108.0/22",
              "140.82.112.0/20",
              "143.55.64.0/20",
              # ... other IPs
            ]
          }
        }
      }
    ]
  })
}
```

### Method 3: IP Restriction within Lambda Function

#### Overview
Implement IP checking before Lambda Web Adapter.

#### Drawbacks
- Increased Lambda execution time (higher cost)
- Complex implementation
- Difficult maintenance

#### Implementation Example (Reference)

Custom Dockerfile with IP restriction script:

```dockerfile
FROM ghcr.io/github-copilot-resources/copilot-metrics-viewer:latest

# IP restriction script
COPY ip-filter.sh /opt/ip-filter.sh
RUN chmod +x /opt/ip-filter.sh

# Lambda Web Adapter
COPY --from=public.ecr.aws/awsguru/aws-lambda-adapter:0.8.4 /lambda-adapter /opt/extensions/lambda-adapter

ENV PORT=8080
ENV NITRO_PORT=8080
ENV AWS_LAMBDA_EXEC_WRAPPER=/opt/ip-filter.sh
```

`ip-filter.sh`:
```bash
#!/bin/bash

# Get client IP
CLIENT_IP=$(echo "$AWS_LAMBDA_FUNCTION_EVENT" | jq -r '.requestContext.http.sourceIp')

# Allowed IP ranges
ALLOWED_RANGES="192.30.252.0/22 185.199.108.0/22 140.82.112.0/20 143.55.64.0/20"

# IP check (simplified version)
ALLOWED=false
for range in $ALLOWED_RANGES; do
  # CIDR range check logic (needs implementation)
  if check_ip_in_range "$CLIENT_IP" "$range"; then
    ALLOWED=true
    break
  fi
done

if [ "$ALLOWED" = false ]; then
  echo '{"statusCode": 403, "body": "Forbidden"}'
  exit 0
fi

# Execute original application
exec "$@"
```

## Recommended Implementation

**CloudFront + AWS WAF** is recommended.

Reasons:
- Most flexible and manageable
- Performance improvement
- Enhanced security
- Reasonable cost (~$6-10/month)

## GitHub IP Range Updates

GitHub IP ranges may change, so periodic verification is required.

```bash
# Get latest IP ranges
curl -s https://api.github.com/meta | jq '.web'
```

Auto-update script example:
```bash
#!/bin/bash
# update-github-ips.sh

# Get GitHub IPs
GITHUB_IPS=$(curl -s https://api.github.com/meta | jq -r '.web[]')

# Update WAF IP Set
aws wafv2 update-ip-set \
  --scope CLOUDFRONT \
  --id <ip-set-id> \
  --addresses $GITHUB_IPS \
  --lock-token <lock-token>
```

## References

- [GitHub IP Addresses](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/about-githubs-ip-addresses)
- [AWS WAF Documentation](https://docs.aws.amazon.com/waf/)
- [CloudFront + Lambda Function URL](https://aws.amazon.com/blogs/compute/using-amazon-cloudfront-with-aws-lambda-as-origin/)
