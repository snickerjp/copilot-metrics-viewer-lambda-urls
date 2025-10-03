````markdown
# Lambda Function URL IP制限実装ガイド

## 概要

Lambda Function URLに対して、以下のIPアドレスからのアクセスのみを許可する方法。

### 許可するIPレンジ

1. **GitHub OAuth Callback**
   - `192.30.252.0/22`
   - `185.199.108.0/22`
   - `140.82.112.0/20`
   - `143.55.64.0/20`
   - Azure経由の個別IP (20.x.x.x, 4.x.x.x)

## 実装方法

### 方法1: CloudFront + AWS WAF (推奨)

#### アーキテクチャ
```
User/GitHub → CloudFront → AWS WAF → Lambda Function URL
```

#### メリット
- WAFで柔軟なIP制限
- CloudFrontのキャッシュで高速化・コスト削減
- DDoS保護
- SSL証明書管理が簡単

#### コスト
- CloudFront: $0.085/GB (最初の10TB)
- WAF: $5/月 + $1/ルール
- 合計: 月$6-10程度

#### Terraform実装例

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
    name     = "AllowGitHubAndFAN"
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
      metric_name                = "AllowGitHubAndFAN"
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

#### デプロイ手順

1. WAFとCloudFrontリソースを追加
```bash
terraform apply
```

2. CloudFrontのドメイン名を取得
```bash
terraform output cloudfront_domain
```

3. GitHub AppのCallback URLを更新
   - `https://<cloudfront-domain>/api/auth/github`

### 方法2: API Gateway + Lambda

#### アーキテクチャ
```
User/GitHub → API Gateway (リソースポリシー) → Lambda
```

#### メリット
- API Gatewayのリソースポリシーで直接IP制限
- CloudFrontより設定が簡単

#### デメリット
- Lambda Function URLを使わない（別の統合が必要）
- コストがやや高い（$3.50/100万リクエスト）

#### Terraform実装例

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

# リソースポリシーでIP制限
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
              # ... 他のIP
            ]
          }
        }
      }
    ]
  })
}
```

### 方法3: Lambda関数内でIP制限

#### 概要
Lambda Web Adapterの前段でIPチェックを実装。

#### デメリット
- Lambda実行時間が増える（コスト増）
- 実装が複雑
- メンテナンスが大変

#### 実装例（参考）

カスタムDockerfileでIP制限スクリプトを追加:

```dockerfile
FROM ghcr.io/github-copilot-resources/copilot-metrics-viewer:latest

# IP制限スクリプト
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

# クライアントIPを取得
CLIENT_IP=$(echo "$AWS_LAMBDA_FUNCTION_EVENT" | jq -r '.requestContext.http.sourceIp')

# 許可IPリスト
ALLOWED_RANGES="192.30.252.0/22 185.199.108.0/22 140.82.112.0/20 143.55.64.0/20"

# IPチェック（簡易版）
ALLOWED=false
for range in $ALLOWED_RANGES; do
  # CIDR範囲チェックロジック（要実装）
  if check_ip_in_range "$CLIENT_IP" "$range"; then
    ALLOWED=true
    break
  fi
done

if [ "$ALLOWED" = false ]; then
  echo '{"statusCode": 403, "body": "Forbidden"}'
  exit 0
fi

# 元のアプリケーションを実行
exec "$@"
```

## 推奨実装

**CloudFront + AWS WAF** を推奨します。

理由:
- 最も柔軟で管理しやすい
- パフォーマンス向上
- セキュリティ強化
- コストも妥当（月$6-10）

## GitHub IPレンジの更新

GitHubのIPレンジは変更される可能性があるため、定期的に確認が必要です。

```bash
# 最新のIPレンジを取得
curl -s https://api.github.com/meta | jq '.web'
```

自動更新スクリプト例:
```bash
#!/bin/bash
# update-github-ips.sh

# GitHub IPを取得
GITHUB_IPS=$(curl -s https://api.github.com/meta | jq -r '.web[]')

# WAF IP Setを更新
aws wafv2 update-ip-set \
  --scope CLOUDFRONT \
  --id <ip-set-id> \
  --addresses $GITHUB_IPS \
  --lock-token <lock-token>
```

## 参考リンク

- [GitHub IP Addresses](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/about-githubs-ip-addresses)
- [AWS WAF Documentation](https://docs.aws.amazon.com/waf/)
- [CloudFront + Lambda Function URL](https://aws.amazon.com/blogs/compute/using-amazon-cloudfront-with-aws-lambda-as-origin/)

````
