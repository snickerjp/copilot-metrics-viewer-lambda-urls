````markdown
# Secrets管理ガイド

## 問題: terraform.tfvarsに平文でsecretを保存

現在の方式:
```hcl
environment_variables = {
  NUXT_SESSION_PASSWORD       = "aqcD5P1/FIoT1iVoToxMTLLhTJYf0hhv"
  NUXT_OAUTH_GITHUB_CLIENT_SECRET = "58233c645195da146753a3999f0f1b2e1018bd67"
}
```

**リスク**:
- ❌ Gitにコミットされる可能性
- ❌ 平文保存
- ❌ アクセス制御が困難
- ❌ ローテーションが手動

## 解決策

### 方法1: AWS Secrets Manager（推奨）

#### メリット
- ✅ 暗号化保存
- ✅ アクセス制御（IAM）
- ✅ 自動ローテーション
- ✅ 監査ログ
- ✅ バージョン管理

#### コスト
- $0.40/secret/月
- $0.05/10,000 API呼び出し
- 合計: 月$1-2程度

#### 実装手順

##### 1. Secretsを作成

```bash
# セッションパスワード
aws secretsmanager create-secret \
  --name copilot-metrics-viewer/session-password \
  --secret-string "aqcD5P1/FIoT1iVoToxMTLLhTJYf0hhv" \
  --region ap-northeast-1

# GitHub Client Secret
aws secretsmanager create-secret \
  --name copilot-metrics-viewer/github-client-secret \
  --secret-string "58233c645195da146753a3999f0f1b2e1018bd67" \
  --region ap-northeast-1

# GitHub Token (Personal Access Token使用時)
aws secretsmanager create-secret \
  --name copilot-metrics-viewer/github-token \
  --secret-string "ghp_xxxxxxxxxxxx" \
  --region ap-northeast-1
```

##### 2. Terraformを更新

```hcl
# secrets.tf
data "aws_secretsmanager_secret" "session_password" {
  name = "copilot-metrics-viewer/session-password"
}

data "aws_secretsmanager_secret_version" "session_password" {
  secret_id = data.aws_secretsmanager_secret.session_password.id
}

data "aws_secretsmanager_secret" "github_client_secret" {
  name = "copilot-metrics-viewer/github-client-secret"
}

data "aws_secretsmanager_secret_version" "github_client_secret" {
  secret_id = data.aws_secretsmanager_secret.github_client_secret.id
}

# main.tf
resource "aws_lambda_function" "app" {
  # ... 既存の設定 ...
  
  environment {
    variables = merge(
      var.environment_variables,
      {
        AWS_LAMBDA_EXEC_WRAPPER         = "/opt/bootstrap"
        PORT                            = "8080"
        NUXT_SESSION_PASSWORD           = data.aws_secretsmanager_secret_version.session_password.secret_string
        NUXT_OAUTH_GITHUB_CLIENT_SECRET = data.aws_secretsmanager_secret_version.github_client_secret.secret_string
      }
    )
  }
}

# Lambda関数にSecrets Managerへのアクセス権限を付与
resource "aws_iam_role_policy" "lambda_secrets" {
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue"
      ]
      Resource = [
        data.aws_secretsmanager_secret.session_password.arn,
        data.aws_secretsmanager_secret.github_client_secret.arn
      ]
    }]
  })
}
```

##### 3. terraform.tfvarsを更新

```hcl
# terraform.tfvars
environment_variables = {
  # Secretsは削除（Secrets Managerから取得）
  # NUXT_SESSION_PASSWORD = "..." ← 削除
  # NUXT_OAUTH_GITHUB_CLIENT_SECRET = "..." ← 削除
  
  # 公開情報のみ記載
  NUXT_PUBLIC_USING_GITHUB_AUTH = "true"
  NUXT_OAUTH_GITHUB_CLIENT_ID   = "Iv23litzHDHNThfof4oz"
  NUXT_PUBLIC_SCOPE              = "organization"
  NUXT_PUBLIC_GITHUB_ORG         = "a8-engineer"
}
```

##### 4. デプロイ

```bash
terraform apply
```

---

### 方法2: 環境変数（開発環境向け）

...（省略、元文を保持）

## 推奨実装: AWS Secrets Manager

本番環境では**AWS Secrets Manager**を強く推奨します。

### 実装の優先順位

1. **今すぐ**: `.gitignore`に`terraform.tfvars`を追加
2. **短期**: 環境変数方式に移行
3. **長期**: AWS Secrets Managerに移行

## 参考リンク

- [AWS Secrets Manager](https://docs.aws.amazon.com/secretsmanager/)
- [Terraform Sensitive Variables](https://developer.hashicorp.com/terraform/language/values/variables#suppressing-values-in-cli-output)
- [Git History Cleanup](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository)

````
