# ---------------------------------------------------------- COMPUTE (container hosts)
# Each tier is a Launch Template + Auto Scaling Group of Amazon Linux 2023
# hosts. User data installs Docker, reads the release tag from SSM, pulls the
# image from ECR and runs it. Hosts are disposable: a release replaces them
# (instance refresh) instead of patching them in place.

data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  # Amazon-provided DNS resolver is always at VPC base + 2 (10.0.0.2)
  vpc_dns = cidrhost(var.vpc_cidr, 2)
}

# ---------------- Web tier
resource "aws_launch_template" "web" {
  name_prefix   = "${var.project}-web-"
  image_id      = data.aws_ssm_parameter.al2023_ami.value
  instance_type = var.instance_type

  iam_instance_profile {
    name = local.instance_profile
  }

  vpc_security_group_ids = [aws_security_group.web.id]

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only (blocks SSRF-style credential theft)
    http_put_response_hop_limit = 1          # Nginx container never calls AWS, so it cannot reach role credentials
  }

  monitoring {
    enabled = true # 1-minute CloudWatch metrics, faster scaling reactions
  }

  # replace() strips Windows line endings, which would break the bash script
  user_data = base64encode(replace(templatefile("${path.module}/templates/web_user_data.sh.tftpl", {
    region     = var.region
    registry   = local.registry
    image_repo = aws_ecr_repository.web.repository_url
    tag_param  = aws_ssm_parameter.image_tag["web"].name
    app_host   = aws_lb.app.dns_name
    resolver   = local.vpc_dns
    log_group  = aws_cloudwatch_log_group.web.name
  }), "\r", ""))

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.project}-web", Tier = "web" }
  }
}

resource "aws_autoscaling_group" "web" {
  name                      = "${var.project}-web-asg"
  vpc_zone_identifier       = aws_subnet.public[*].id
  min_size                  = var.web_min
  max_size                  = var.web_max
  desired_capacity          = var.web_min
  target_group_arns         = [aws_lb_target_group.web.arn]
  health_check_type         = "ELB" # replace hosts the ALB marks unhealthy, not only crashed ones
  health_check_grace_period = 300
  default_instance_warmup   = 120

  launch_template {
    id      = aws_launch_template.web.id
    version = "$Latest"
  }

  # Rolling replacement when the launch template changes
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.project}-web"
    propagate_at_launch = true
  }

  lifecycle {
    ignore_changes = [desired_capacity] # owned by the scaling policy
  }
}

# ---------------- App tier
resource "aws_launch_template" "app" {
  name_prefix   = "${var.project}-app-"
  image_id      = data.aws_ssm_parameter.al2023_ami.value
  instance_type = var.instance_type

  iam_instance_profile {
    name = local.instance_profile
  }

  vpc_security_group_ids = [aws_security_group.app.id]

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2 # the Flask container calls Secrets Manager with the role credentials
  }

  monitoring {
    enabled = true
  }

  user_data = base64encode(replace(templatefile("${path.module}/templates/app_user_data.sh.tftpl", {
    region     = var.region
    registry   = local.registry
    image_repo = aws_ecr_repository.app.repository_url
    tag_param  = aws_ssm_parameter.image_tag["app"].name
    secret_arn = aws_secretsmanager_secret.db.arn
    db_name    = var.db_name
    log_group  = aws_cloudwatch_log_group.app.name
  }), "\r", ""))

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.project}-app", Tier = "app" }
  }
}

resource "aws_autoscaling_group" "app" {
  name                      = "${var.project}-app-asg"
  vpc_zone_identifier       = aws_subnet.private_app[*].id
  min_size                  = var.app_min
  max_size                  = var.app_max
  desired_capacity          = var.app_min
  target_group_arns         = [aws_lb_target_group.app.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 300
  default_instance_warmup   = 120

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.project}-app"
    propagate_at_launch = true
  }

  lifecycle {
    ignore_changes = [desired_capacity]
  }

  # The secret version (with the DB host) must exist before the first app host boots
  depends_on = [aws_secretsmanager_secret_version.db, aws_nat_gateway.nat]
}

# ---------------- Elasticity: target-tracking scaling policies
# AWS adds/removes hosts to keep average CPU near the target. Scale-in is automatic too.
resource "aws_autoscaling_policy" "web_cpu" {
  name                   = "${var.project}-web-cpu-target"
  autoscaling_group_name = aws_autoscaling_group.web.name
  policy_type            = "TargetTrackingScaling"
  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = var.cpu_target
  }
}

resource "aws_autoscaling_policy" "app_cpu" {
  name                   = "${var.project}-app-cpu-target"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"
  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = var.cpu_target
  }
}
