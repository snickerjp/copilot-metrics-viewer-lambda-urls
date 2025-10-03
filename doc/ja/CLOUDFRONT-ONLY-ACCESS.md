````markdown
# CloudFront経由のみアクセス許可する方法

## 問題

Lambda Function URLは推測可能なため、CloudFrontを経由せずに直接アクセスされる可能性があります。

## 解決策

### 方法1: IAM認証 + CloudFront署名（最も安全）

#### 概要
- Lambda Function URLを`AWS_IAM`認証に変更
- CloudFrontにIAMロールを付与してSigV4署名でアクセス
- 直接アクセスは認証エラーで拒否

#### Terraform実装

```hcl
# Lambda Function URLをIAM認証に変更
resource "aws_lambda_function_url" "app" {
  function_name      = aws_lambda_function.app.function_name
  authorization_type = "AWS_IAM"  # NONEから変更

  cors {
    allow_origins     = ["*"]
    allow_methods     = ["*"]
    allow_headers     = ["*"]
    expose_headers    = ["*"]
    max_age          = 86400
  }
}

# CloudFront用のIAMロール
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

# Lambda呼び出し権限
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
    
    # IAM認証設定
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

# Origin Access Control (Lambda Function URL用)
resource "aws_cloudfront_origin_access_control" "lambda" {
  name                              = "lambda-oac"
  origin_access_control_origin_type = "lambda"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Lambda Function URLのリソースポリシー
resource "aws_lambda_permission" "cloudfront_invoke" {
  statement_id  = "AllowCloudFrontInvoke"
  action        = "lambda:InvokeFunctionUrl"
  function_name = aws_lambda_function.app.function_name
  principal     = "cloudfront.amazonaws.com"
  source_arn    = aws_cloudfront_distribution.app.arn
}
```

#### メリット
- 最も安全（IAM認証）
- 直接アクセスは完全にブロック
- AWSのベストプラクティス

#### デメリット
- 設定がやや複雑
- CloudFrontのOAC（Origin Access Control）が必要

---

### 方法2: カスタムヘッダー検証（簡易・推奨）

#### 概要
- CloudFrontから秘密のカスタムヘッダーを送信
- Lambda Web Adapterの前段でヘッダーを検証
- ヘッダーがない場合は403を返す

#### Terraform実装

```hcl
# ランダムな秘密文字列を生成
resource "random_password" "cloudfront_secret" {
  length  = 32
  special = true
}

# Lambda環境変数に秘密を設定
resource "aws_lambda_function" "app" {
  # ... 既存の設定 ...
  
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
    
    # カスタムヘッダーを追加
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

#### Lambda側の検証実装

カスタムDockerfileを作成:

```dockerfile
FROM ghcr.io/github-copilot-resources/copilot-metrics-viewer:latest

# ヘッダー検証スクリプト
COPY cloudfront-check.js /opt/cloudfront-check.js

# Lambda Web Adapter
COPY --from=public.ecr.aws/awsguru/aws-lambda-adapter:0.8.4 /lambda-adapter /opt/extensions/lambda-adapter

ENV PORT=8080
ENV NITRO_PORT=8080
```

`cloudfront-check.js` (Lambda Web Adapterの拡張):

```javascript
// Lambda Web Adapterのイベント変換前にチェック
const originalHandler = require('/var/runtime/bootstrap');

exports.handler = async (event, context) => {
  // CloudFrontヘッダーをチェック
  const headers = event.headers || {};
  const cloudfrontSecret = headers['x-cloudfront-secret'];
  const expectedSecret = process.env.CLOUDFRONT_SECRET;
  
  if (cloudfrontSecret !== expectedSecret) {
    return {
      statusCode: 403,
      body: JSON.stringify({ message: 'Forbidden' })
    };
  }
  
  // 正当なリクエストは元のハンドラーに渡す
  return originalHandler.handler(event, context);
};
```

#### より簡単な実装: Nitro Middleware

Nuxtアプリ内でミドルウェアを追加（アプリ側の変更が必要）:

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

#### メリット
- 実装が簡単
- 既存のLambda Function URL（NONE認証）をそのまま使える
- コストが安い

#### デメリット
- ヘッダーが漏洩すると突破される（定期的にローテーション推奨）
- IAM認証ほど安全ではない

---

### 方法3: AWS WAFでCloudFrontのIPのみ許可

#### 概要
CloudFrontのIPレンジのみを許可するWAFルールを作成。

#### 問題点
- CloudFrontのIPレンジは広大で頻繁に変更される
- 他のCloudFrontユーザーもアクセス可能
- **非推奨**

---

## 推奨実装

### 短期的（すぐに実装）
**方法2: カスタムヘッダー検証**

理由:
- 実装が簡単
- 既存の構成を大きく変更しない
- 十分なセキュリティレベル

### 長期的（本番運用）
**方法1: IAM認証 + CloudFront署名**

理由:
- 最も安全
- AWSのベストプラクティス
- ヘッダー漏洩のリスクなし

## 実装手順（カスタムヘッダー方式）

### 1. Terraformに追加

```bash
# main.tfに追加
terraform apply
```

### 2. Dockerfileを更新

アプリ側でミドルウェアを追加するか、カスタムDockerfileを作成。

### 3. イメージを再ビルド・デプロイ

```bash
# CloudShellで実行
bash build-and-push.sh ap-northeast-1 latest

# Lambda関数を更新
aws lambda update-function-code \
  --function-name copilot-metrics-viewer \
  --image-uri <ECR-URI>:latest \
  --region ap-northeast-1
```

### 4. 動作確認

```bash
# CloudFront経由（成功）
curl https://<cloudfront-domain>/

# 直接アクセス（403エラー）
curl https://<lambda-function-url>/
```

## セキュリティのベストプラクティス

1. **秘密のローテーション**: 定期的にカスタムヘッダーの値を変更
2. **CloudWatch監視**: 直接アクセスの試行を監視
3. **WAFとの併用**: IP制限とヘッダー検証を両方実装

## 参考リンク

- [CloudFront Origin Access Control](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-restricting-access-to-lambda.html)
- [Lambda Function URL Authorization](https://docs.aws.amazon.com/lambda/latest/dg/urls-auth.html)

````
