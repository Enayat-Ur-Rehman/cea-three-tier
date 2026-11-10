# ---------------------------------------------------------------- IAM (instance role)
# EC2 hosts get temporary credentials from an instance role, so no AWS keys
# are ever stored on a server. The role allows only what the hosts need.
#
# AWS Academy Learner Lab blocks iam:CreateRole. There, set
# existing_instance_profile = "LabInstanceProfile" and none of this is created.

locals {
  create_iam       = var.existing_instance_profile == ""
  instance_profile = local.create_iam ? aws_iam_instance_profile.ec2[0].name : var.existing_instance_profile
}

resource "aws_iam_role" "ec2" {
  count = local.create_iam ? 1 : 0
  name  = "${var.project}-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Pull images from ECR (read-only)
resource "aws_iam_role_policy_attachment" "ecr_read" {
  count      = local.create_iam ? 1 : 0
  role       = aws_iam_role.ec2[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# SSM Session Manager shell access instead of SSH keys and port 22
resource "aws_iam_role_policy_attachment" "ssm_core" {
  count      = local.create_iam ? 1 : 0
  role       = aws_iam_role.ec2[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Scoped permissions: this project's secret, parameters and log groups only
resource "aws_iam_role_policy" "app_access" {
  count = local.create_iam ? 1 : 0
  name  = "${var.project}-scoped-access"
  role  = aws_iam_role.ec2[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadDbSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.db.arn
      },
      {
        Sid      = "ReadReleaseTags"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "arn:aws:ssm:${var.region}:${local.account_id}:parameter/${var.project}/*"
      },
      {
        Sid    = "WriteContainerLogs"
        Effect = "Allow"
        Action = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
        Resource = [
          "${aws_cloudwatch_log_group.web.arn}:*",
          "${aws_cloudwatch_log_group.app.arn}:*",
        ]
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  count = local.create_iam ? 1 : 0
  name  = "${var.project}-ec2-profile"
  role  = aws_iam_role.ec2[0].name
}
