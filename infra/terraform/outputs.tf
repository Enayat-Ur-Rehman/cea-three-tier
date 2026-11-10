output "app_url" {
  description = "Open this in a browser (HTTPS via CloudFront)"
  value       = "https://${aws_cloudfront_distribution.web.domain_name}"
}

output "public_alb_dns" {
  description = "Direct ALB address. Answers 403 / is unreachable: only CloudFront may call it."
  value       = aws_lb.web.dns_name
}

output "cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.web.id
}

output "deploy_role_arn" {
  description = "Set as the GitHub repository variable AWS_DEPLOY_ROLE_ARN"
  value       = local.create_github_oidc ? aws_iam_role.github_deploy[0].arn : ""
}

output "internal_alb_dns" {
  value = aws_lb.app.dns_name
}

output "ecr_web_repository" {
  value = aws_ecr_repository.web.repository_url
}

output "ecr_app_repository" {
  value = aws_ecr_repository.app.repository_url
}

output "rds_endpoint" {
  value = aws_db_instance.mysql.address
}

output "db_secret_arn" {
  value = aws_secretsmanager_secret.db.arn
}

output "web_asg_name" {
  value = aws_autoscaling_group.web.name
}

output "app_asg_name" {
  value = aws_autoscaling_group.app.name
}

output "web_target_group_arn" {
  value = aws_lb_target_group.web.arn
}

output "app_target_group_arn" {
  value = aws_lb_target_group.app.arn
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "dashboard_url" {
  value = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}"
}
