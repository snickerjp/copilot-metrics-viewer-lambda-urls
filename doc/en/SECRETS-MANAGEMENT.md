# Secrets Management Guide

## Problem: Storing Secrets in Plain Text in terraform.tfvars

Current approach:
```hcl
environment_variables = {
  NUXT_SESSION_PASSWORD       = "aqcD5P1/FIoT1iVoToxMTLLhTJYf0hhv"
  NUXT_OAUTH_GITHUB_CLIENT_SECRET = "58233c645195da146753a3999f0f1b2e1018bd67"
}
```

**Risks**:
- ❌ May be committed to Git
- ❌ Plain text storage
- ❌ Difficult access control
- ❌ Manual rotation

## Solutions

### Method 1: AWS Secrets Manager (Recommended)

#### Benefits
- ✅ Encrypted storage
- ✅ Access control (IAM)
- ✅ Automatic rotation
- ✅ Audit logs
- ✅ Version management

#### Cost
- $0.40/secret/month
- $0.05/10,000 API calls
- Total: ~$1-2/month

#### Implementation Steps

##### 1. Create Secrets

```bash
# Session password
aws secretsmanager create-secret \
  --name copilot-metrics-viewer/session-password \
  --secret-string "aqcD5P1/FIoT1iVoToxMTLLhTJYf0hhv" \
  --region ap-northeast-1

# GitHub Client Secret
aws secretsmanager create-secret \
  --name copilot-metrics-viewer/github-client-secret \
  --secret-string "58233c645195da146753a3999f0f1b2e1018bd67" \
  --region ap-northeast-1

# GitHub Token (when using Personal Access Token)
aws secretsmanager create-secret \
  --name copilot-metrics-viewer/github-token \
  --secret-string "ghp_xxxxxxxxxxxx" \
  --region ap-northeast-1
```

##### 2. Update Terraform

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
  # ... existing configuration ...
  
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

# Grant Lambda function access to Secrets Manager
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

##### 3. Update terraform.tfvars

```hcl
# terraform.tfvars
environment_variables = {
  # Remove secrets (retrieved from Secrets Manager)
  # NUXT_SESSION_PASSWORD = "..." ← Remove
  # NUXT_OAUTH_GITHUB_CLIENT_SECRET = "..." ← Remove
  
  # Only public information
  NUXT_PUBLIC_USING_GITHUB_AUTH = "true"
  NUXT_OAUTH_GITHUB_CLIENT_ID   = "Iv23litzHDHNThfof4oz"
  NUXT_PUBLIC_SCOPE              = "organization"
  NUXT_PUBLIC_GITHUB_ORG         = "your-org-name"
}
```

##### 4. Deploy

```bash
terraform apply
```

---

### Method 2: Environment Variables (For Development)

#### Overview
Use local environment variables instead of terraform.tfvars.

#### Implementation

##### 1. Create .env file (local only)

```bash
# .env (add to .gitignore)
export TF_VAR_session_password="aqcD5P1/FIoT1iVoToxMTLLhTJYf0hhv"
export TF_VAR_github_client_secret="58233c645195da146753a3999f0f1b2e1018bd67"
```

##### 2. Update variables.tf

```hcl
# variables.tf
variable "session_password" {
  description = "Session encryption password"
  type        = string
  sensitive   = true
}

variable "github_client_secret" {
  description = "GitHub OAuth client secret"
  type        = string
  sensitive   = true
}
```

##### 3. Update main.tf

```hcl
# main.tf
resource "aws_lambda_function" "app" {
  environment {
    variables = merge(
      var.environment_variables,
      {
        NUXT_SESSION_PASSWORD           = var.session_password
        NUXT_OAUTH_GITHUB_CLIENT_SECRET = var.github_client_secret
      }
    )
  }
}
```

##### 4. Load environment and deploy

```bash
# Load environment variables
source .env

# Deploy
terraform apply
```

#### Benefits
- ✅ No plain text in files
- ✅ Simple implementation
- ✅ No additional AWS costs

#### Drawbacks
- ❌ Manual management
- ❌ No centralized management
- ❌ Difficult to share across team

---

### Method 3: Terraform Cloud/Enterprise

#### Overview
Use Terraform Cloud's sensitive variable management.

#### Benefits
- ✅ Centralized management
- ✅ Team collaboration
- ✅ Audit logs
- ✅ Integration with CI/CD

#### Drawbacks
- ❌ Additional service cost
- ❌ Vendor lock-in

---

## Recommended Implementation: AWS Secrets Manager

**AWS Secrets Manager** is strongly recommended for production environments.

### Implementation Priority

1. **Immediate**: Add `terraform.tfvars` to `.gitignore`
2. **Short-term**: Migrate to environment variable approach
3. **Long-term**: Migrate to AWS Secrets Manager

### Security Best Practices

1. **Never commit secrets to Git**
   ```bash
   # Add to .gitignore
   echo "terraform.tfvars" >> .gitignore
   echo ".env" >> .gitignore
   ```

2. **Use different secrets per environment**
   - Development: Simple environment variables
   - Staging/Production: AWS Secrets Manager

3. **Regular rotation**
   ```bash
   # Rotate GitHub Client Secret
   aws secretsmanager rotate-secret \
     --secret-id copilot-metrics-viewer/github-client-secret
   ```

4. **Principle of least privilege**
   - Grant minimal IAM permissions
   - Use resource-specific ARNs

### Migration Steps

#### Step 1: Immediate Security (5 minutes)

```bash
# 1. Add to .gitignore
echo "terraform.tfvars" >> .gitignore

# 2. Remove from Git history (if already committed)
git filter-branch --force --index-filter \
  'git rm --cached --ignore-unmatch terraform.tfvars' \
  --prune-empty --tag-name-filter cat -- --all

# 3. Force push (⚠️ Coordinate with team)
git push origin --force --all
```

#### Step 2: Environment Variables (30 minutes)

Implement Method 2 above.

#### Step 3: AWS Secrets Manager (1 hour)

Implement Method 1 above.

## References

- [AWS Secrets Manager](https://docs.aws.amazon.com/secretsmanager/)
- [Terraform Sensitive Variables](https://developer.hashicorp.com/terraform/language/values/variables#suppressing-values-in-cli-output)
- [Git History Cleanup](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository)
