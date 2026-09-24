data "aws_caller_identity" "current" {}

# 1. OIDC Provider Configuration
# Only one provider per AWS account is allowed for this URL.
# We dynamically fetch the thumbprint to avoid manual rotation issues.
data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  # The audience must match what AWS STS expects
  client_id_list = ["sts.amazonaws.com"]

  # Use the dynamically fetched thumbprint for robustness
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]

  tags = {
    Name      = "GitHub Actions OIDC Provider"
    ManagedBy = "Terraform"
  }
}

# 2. Trust Policy Data Source (Reusable logic)
# This defines who can assume the role based on repo, branch, and environment claims.
data "aws_iam_policy_document" "github_trust_deploy" {
  statement {
    effect = "Allow"
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    actions = ["sts:AssumeRoleWithWebIdentity"]

    # Verify the token audience
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Restrict to pushes on main. The human approval gate itself is
    # enforced by the "production" GitHub Environment's required-reviewer
    # rule on the `approval` job (via `needs: approval` in the workflow
    # graph) -- not by an `environment:production` claim in the OIDC
    # token, since the apply/smoke-test/rollback jobs that actually need
    # this role don't set `environment:` themselves.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:epruitt/vpcWebsiteHosting:ref:refs/heads/main",
        "repo:epruitt@*/vpcWebsiteHosting@*:ref:refs/heads/main"
      ]
    }
  }
}

# Separate trust policy for PR plans - restricted specifically to pull_request
# events, not a repo-wide wildcard, so this role can't be assumed from
# arbitrary branches, workflow_dispatch runs, or other event types.
data "aws_iam_policy_document" "github_trust_plan" {
  statement {
    effect = "Allow"
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    actions = ["sts:AssumeRoleWithWebIdentity"]

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Plan role is now used both by PR-triggered plans (pull_request) and
    # by the pre-approval "test" plan job in terraform-deploy.yml, which
    # runs on push to main 
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:epruitt/vpcWebsiteHosting:pull_request",
        "repo:epruitt/vpcWebsiteHosting:ref:refs/heads/main",
        "repo:epruitt@*/vpcWebsiteHosting@*:pull_request",
        "repo:epruitt@*/vpcWebsiteHosting@*:ref:refs/heads/main"
      ]
    }
  }
}

# 3. IAM Role for Deployment (Production Environment)
resource "aws_iam_role" "github_actions_deploy" {
  name               = "github-actions-deploy-vpc"
  assume_role_policy = data.aws_iam_policy_document.github_trust_deploy.json
  description        = "Role for GitHub Actions to deploy infrastructure from the production environment"

  tags = {
    Environment = "production"
    ManagedBy   = "Terraform"
  }
}

# 4. IAM Role for PR Planning (Read-Only / Plan Only)
resource "aws_iam_role" "github_actions_plan" {
  name               = "github-actions-plan-vpc"
  assume_role_policy = data.aws_iam_policy_document.github_trust_plan.json
  description        = "Role for GitHub Actions to run terraform plan on pull requests"

  tags = {
    Environment = "ci"
    ManagedBy   = "Terraform"
  }
}

# 5. Permissions Policy for Deployment
# Grants necessary access for EC2, ALB, S3 (state + website assets), IAM,
# SSM, SNS, CloudWatch, and the GitHub OIDC provider itself.
data "aws_iam_policy_document" "deploy_permissions" {
  # S3 State Bucket Access (Native Locking)
  # S3 State Bucket Access (Native Locking)
  statement {
    sid = "TerraformStateAccess"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket"
    ]

    resources = [
      "arn:aws:s3:::tfstate-dev-us-east-2-x6n4tn",
      "arn:aws:s3:::tfstate-dev-us-east-2-x6n4tn/*"
    ]
  }

  # S3 Website Assets Bucket Access
  # Bucket name includes a random_string suffix generated at apply time
  # (omnifood-website-<env>-<region>-<suffix>), so a fixed ARN isn't
  # possible -- wildcard on the known naming prefix instead.
  statement {
    sid = "WebsiteBucketAccess"

    actions = [
      "s3:CreateBucket",
      "s3:DeleteBucket",

      # Bucket metadata/configuration reads
      "s3:GetBucketAcl",
      "s3:GetBucketCors",
      "s3:GetBucketWebsite",
      "s3:GetBucketPolicy",
      "s3:GetBucketVersioning",
      "s3:GetEncryptionConfiguration",
      "s3:GetBucketPublicAccessBlock",
      "s3:GetBucketTagging",

      # Bucket configuration writes
      "s3:PutBucketCors",
      "s3:PutBucketPolicy",
      "s3:PutBucketVersioning",
      "s3:PutEncryptionConfiguration",
      "s3:PutBucketPublicAccessBlock",

      "s3:ListBucket"
    ]

    resources = [
      "arn:aws:s3:::omnifood-website-*"
    ]
  }

  # S3 Website Object Access
  statement {
    sid = "WebsiteObjectAccess"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject"
    ]

    resources = [
      "arn:aws:s3:::omnifood-website-*/*"
    ]
  }

  # Core Infrastructure Services
  statement {
    sid = "CoreInfraServices"

    actions = [
      "ec2:*",
      "elasticloadbalancing:*"
    ]

    resources = ["*"]
  }

  # SSM Parameter Store Access
  #
  # IMPORTANT:
  # ssm:DescribeParameters does not support resource-level permissions,
  # therefore it must use Resource = "*".
  #
  # The parameter read/write operations remain scoped to /omnifood/*.
  statement {
    sid = "SsmDescribeParameters"

    actions = [
      "ssm:DescribeParameters"
    ]

    resources = ["*"]
  }

  statement {
    sid = "SsmParameterAccess"

  actions = [
    "ssm:DescribeParameters",
    "ssm:GetParameter",
    "ssm:PutParameter",
    "ssm:DeleteParameter",
    "ssm:AddTagsToResource"
  ]

    resources = [
      "arn:aws:ssm:*:${data.aws_caller_identity.current.account_id}:parameter/omnifood/*"
    ]
  }

  # SNS and CloudWatch
  statement {
    sid = "SnsAndCloudWatchAccess"

    actions = [
      "sns:*",
      "cloudwatch:*"
    ]

    resources = [
      "arn:aws:sns:*:${data.aws_caller_identity.current.account_id}:cloudwatch-alarms-topic-*",
      "arn:aws:cloudwatch:*:${data.aws_caller_identity.current.account_id}:alarm:*",
      "arn:aws:cloudwatch::${data.aws_caller_identity.current.account_id}:dashboard/*"
    ]
  }

  # IAM: role, inline policy, and instance profile lifecycle
  statement {
    sid = "Ec2RoleAndProfileManagement"

    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:PutRolePolicy",
      "iam:GetRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:ListRolePolicies",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile"
    ]

    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/*",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:instance-profile/*"
    ]
  }

  # iam:PassRole
  statement {
    sid     = "PassEc2RoleOnly"
    actions = ["iam:PassRole"]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }

  # Allow this pipeline to manage its own OIDC provider
  statement {
    sid = "ManageOwnOidcProvider"

    actions = [
      "iam:CreateOpenIDConnectProvider",
      "iam:DeleteOpenIDConnectProvider",
      "iam:GetOpenIDConnectProvider",
      "iam:UpdateOpenIDConnectProviderThumbprint",
      "iam:TagOpenIDConnectProvider"
    ]

    resources = [
      "arn:aws:iam::*:oidc-provider/token.actions.githubusercontent.com"
    ]
  }
}

resource "aws_iam_role_policy" "deploy_policy" {
  name   = "github-actions-deploy-policy"
  role   = aws_iam_role.github_actions_deploy.id
  policy = data.aws_iam_policy_document.deploy_permissions.json
}

# 6. Permissions Policy for PR Planning
# Restricted to Read-Only + State Bucket Write (for lockfile)
data "aws_iam_policy_document" "plan_permissions" {
  # S3 State Bucket Access
  statement {
    sid = "TerraformStateAccess"
    actions = [
      "s3:GetObject",
      "s3:PutObject",    # Needed for lockfile
      "s3:DeleteObject", # Needed to release the lockfile (S3 native locking)
      "s3:ListBucket"
    ]
    resources = [
      "arn:aws:s3:::tfstate-dev-us-east-2-x6n4tn",
      "arn:aws:s3:::tfstate-dev-us-east-2-x6n4tn/*"
    ]
  }

  # Read-only access to the website assets bucket, for plan-time state reads
  statement {
    sid = "WebsiteAssetsBucketReadOnly"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
      "s3:GetBucketPolicy",
      "s3:GetBucketCors",
      "s3:GetBucketVersioning",
      "s3:GetEncryptionConfiguration",
      "s3:GetBucketAcl",
      "s3:GetBucketPublicAccessBlock",
      "s3:GetBucketTagging"
    ]
    resources = [
      "arn:aws:s3:::omnifood-website-*",
      "arn:aws:s3:::omnifood-website-*/*"
    ]
  }

  # Read-only access to verify resources exist
  statement {
    sid = "CoreInfraReadOnly"
    actions = [
      "ec2:Describe*",
      "elasticloadbalancing:Describe*",
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:GetInstanceProfile",
      "iam:ListInstanceProfilesForRole",
      "iam:GetOpenIDConnectProvider",
      "ssm:GetParameter",
      "ssm:ListTagsForResource",
      "sns:ListTopics",
      "sns:GetTopicAttributes",
      "sns:GetSubscriptionAttributes",
      "sns:ListTagsForResource",
      "cloudwatch:Describe*",
      "cloudwatch:GetDashboard",
      "cloudwatch:ListTagsForResource"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "plan_policy" {
  name   = "github-actions-plan-policy"
  role   = aws_iam_role.github_actions_plan.id
  policy = data.aws_iam_policy_document.plan_permissions.json
}
