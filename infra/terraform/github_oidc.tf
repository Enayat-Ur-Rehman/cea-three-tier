# ------------------------------------------------- CI/CD access: GitHub OIDC (no stored keys)
# GitHub Actions proves who it is with a signed OIDC token. AWS STS swaps that
# token for credentials that expire after about an hour. Only workflow runs on
# the main branch of var.github_repo can assume the role, and the role can only
# push this project's images and roll out this project's servers.
#
# Created in the bootstrap (first, targeted) apply, so its ARNs are built from
# names here instead of referencing the ASGs or CloudFront, which do not exist yet.

locals {
  create_github_oidc = local.create_iam && var.github_repo != ""
}

resource "aws_iam_openid_connect_provider" "github" {
  count          = local.create_github_oidc ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # AWS validates GitHub's tokens against its own trusted CA list; these
  # thumbprints only satisfy the API's input requirement.
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
}

resource "aws_iam_role" "github_deploy" {
  count                = local.create_github_oidc ? 1 : 0
  name                 = "${var.project}-github-deploy"
  max_session_duration = 3600
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github[0].arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          # Only this repository, only the main branch
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:ref:refs/heads/main"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_deploy" {
  count = local.create_github_oidc ? 1 : 0
  name  = "${var.project}-ci-deploy"
  role  = aws_iam_role.github_deploy[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrLogin"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*" # this API has no resource-level permissions
      },
      {
        Sid    = "EcrPushToProjectRepos"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeImages",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
        ]
        Resource = [aws_ecr_repository.web.arn, aws_ecr_repository.app.arn]
      },
      {
        Sid      = "ReadWriteReleaseTags"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:PutParameter"]
        Resource = "arn:aws:ssm:${var.region}:${local.account_id}:parameter/${var.project}/*"
      },
      {
        Sid      = "RollOutProjectServers"
        Effect   = "Allow"
        Action   = ["autoscaling:StartInstanceRefresh", "autoscaling:CancelInstanceRefresh"]
        Resource = "arn:aws:autoscaling:${var.region}:${local.account_id}:autoScalingGroup:*:autoScalingGroupName/${var.project}-*"
      },
      {
        Sid    = "ReadOnlyDescribe"
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeInstanceRefreshes",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeLaunchTemplateVersions",
        ]
        Resource = "*" # Describe APIs have no resource-level permissions
      },
    ]
  })
}
