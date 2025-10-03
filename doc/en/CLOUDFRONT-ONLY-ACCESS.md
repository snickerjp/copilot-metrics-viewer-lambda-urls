# How to Restrict Access to CloudFront Only

## Problem

Lambda Function URLs are predictable, so they can be accessed directly without going through CloudFront.

## Solutions

### Method 1: IAM Authentication + CloudFront Signing (Most Secure)

#### Overview
- Change Lambda Function URL to `AWS_IAM` authentication
- Grant IAM role to CloudFront for SigV4 signed access
- Direct access is rejected with authentication error

#### Terraform Implementation

```hcl
# Change Lambda Function URL to IAM authentication
resource "aws_lambda_function_url" "app" {
  function_name      = aws_lambda_function.app.function_name
  authorization_type = "AWS_IAM"  # Changed from NONE

  cors {
    allow_origins     = ["*"]
    allow_methods     = ["*"]
    allow_headers     = ["*"]
    expose_headers    = ["*"]
    max_age          = 86400
  }
}

# IAM role for CloudFront
resource "aws_iam_role" "cloudfront_lambda_invoke" {
  name = "cloudfront-lambda-invoke-role"

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
}

# Lambda invocation permission
resource "aws_iam_role_policy" "cloudfront_lambda_invoke" {
  role = aws_iam_role.cloudfront_lambda_invoke.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "lambda:InvokeFunctionUrl"
      Resource = aws_lambda_function.app.arn
    }]
  })
}

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
    
    # IAM authentication settings
    origin_access_control_id = aws_cloudfront_origin_access_control.lambda.id
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
}

# Origin Access Control (for Lambda Function URL)
resource "aws_cloudfront_origin_access_control" "lambda" {
  name                              = "lambda-oac"
  origin_access_control_origin_type = "lambda"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Lambda Function URL resource policy
resource "aws_lambda_permission" "cloudfront_invoke" {
  statement_id  = "AllowCloudFrontInvoke"
  action        = "lambda:InvokeFunctionUrl"
  function_name = aws_lambda_function.app.function_name
  principal     = "cloudfront.amazonaws.com"
  source_arn    = aws_cloudfront_distribution.app.arn
}
```

#### Benefits
- Most secure (IAM authentication)
- Direct access is completely blocked
- AWS best practice

#### Drawbacks
- Somewhat complex configuration
- Requires CloudFront OAC (Origin Access Control)

---

### Method 2: Custom Header Validation (Simple & Recommended)

#### Overview
- Send secret custom header from CloudFront
- Validate header before Lambda Web Adapter
- Return 403 if header is missing

#### Terraform Implementation

```hcl
# Generate random secret string
resource "random_password" "cloudfront_secret" {
  length  = 32
  special = true
}

# Set secret in Lambda environment variables
resource "aws_lambda_function" "app" {
  # ... existing configuration ...
  
  environment {
    variables = merge(
      var.environment_variables,
      {
        AWS_LAMBDA_EXEC_WRAPPER = "/opt/bootstrap"
        PORT                    = "8080"
        CLOUDFRONT_SECRET       = random_password.cloudfront_secret.result
      }
    )
  }
}

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
    
    # Add custom header
    custom_header {
      name  = "X-CloudFront-Secret"
      value = random_password.cloudfront_secret.result
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
}
```

#### Lambda-side Validation Implementation

Create custom Dockerfile:

```dockerfile
FROM ghcr.io/github-copilot-resources/copilot-metrics-viewer:latest

# Header validation script
COPY cloudfront-check.js /opt/cloudfront-check.js

# Lambda Web Adapter
COPY --from=public.ecr.aws/awsguru/aws-lambda-adapter:0.8.4 /lambda-adapter /opt/extensions/lambda-adapter

ENV PORT=8080
ENV NITRO_PORT=8080
```

`cloudfront-check.js` (Lambda Web Adapter extension):

```javascript
// Check before Lambda Web Adapter event transformation
const originalHandler = require('/var/runtime/bootstrap');

exports.handler = async (event, context) => {
  // Check CloudFront header
  const headers = event.headers || {};
  const cloudfrontSecret = headers['x-cloudfront-secret'];
  const expectedSecret = process.env.CLOUDFRONT_SECRET;
  
  if (cloudfrontSecret !== expectedSecret) {
    return {
      statusCode: 403,
      body: JSON.stringify({ message: 'Forbidden' })
    };
  }
  
  // Pass legitimate requests to original handler
  return originalHandler.handler(event, context);
};
```

#### Simpler Implementation: Nitro Middleware

Add middleware within Nuxt app (requires app-side changes):

`server/middleware/cloudfront-check.ts`:
```typescript
export default defineEventHandler((event) => {
  const secret = getHeader(event, 'x-cloudfront-secret');
  const expectedSecret = process.env.CLOUDFRONT_SECRET;
  
  if (secret !== expectedSecret) {
    throw createError({
      statusCode: 403,
      message: 'Forbidden'
    });
  }
});
```

#### Benefits
- Simple implementation
- Can use existing Lambda Function URL (NONE authentication) as-is
- Low cost

#### Drawbacks
- Can be bypassed if header leaks (regular rotation recommended)
- Not as secure as IAM authentication

---

### Method 3: AWS WAF Allowing Only CloudFront IPs

#### Overview
Create WAF rules that only allow CloudFront IP ranges.

#### Issues
- CloudFront IP ranges are vast and change frequently
- Other CloudFront users can also access
- **Not recommended**

---

## Recommended Implementation

### Short-term (Immediate Implementation)
**Method 2: Custom Header Validation**

Reasons:
- Simple implementation
- Doesn't require major changes to existing configuration
- Sufficient security level

### Long-term (Production Operation)
**Method 1: IAM Authentication + CloudFront Signing**

Reasons:
- Most secure
- AWS best practice
- No risk of header leakage

## Implementation Steps (Custom Header Method)

### 1. Add to Terraform

```bash
# Add to main.tf
terraform apply
```

### 2. Update Dockerfile

Add middleware on the app side or create custom Dockerfile.

### 3. Rebuild and Deploy Image

```bash
# Run in CloudShell
bash build-and-push.sh ap-northeast-1 latest

# Update Lambda function
aws lambda update-function-code \
  --function-name copilot-metrics-viewer \
  --image-uri <ECR-URI>:latest \
  --region ap-northeast-1
```

### 4. Verify Operation

```bash
# Via CloudFront (success)
curl https://<cloudfront-domain>/

# Direct access (403 error)
curl https://<lambda-function-url>/
```

## Security Best Practices

1. **Secret Rotation**: Regularly change custom header values
2. **CloudWatch Monitoring**: Monitor direct access attempts
3. **Combine with WAF**: Implement both IP restrictions and header validation

## References

- [CloudFront Origin Access Control](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-restricting-access-to-lambda.html)
- [Lambda Function URL Authorization](https://docs.aws.amazon.com/lambda/latest/dg/urls-auth.html)
