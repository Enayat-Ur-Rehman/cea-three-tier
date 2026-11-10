# ---------------------------------------------------------------- LOAD BALANCERS
# Public ALB (internet-facing) in front of the web tier, and an internal ALB
# in front of the app tier. Both span two AZs.

resource "aws_lb" "web" {
  name                       = "${var.project}-web-alb"
  load_balancer_type         = "application"
  internal                   = false
  security_groups            = [aws_security_group.alb_public.id]
  subnets                    = aws_subnet.public[*].id
  drop_invalid_header_fields = true
  tags                       = { Name = "${var.project}-web-alb" }
}

resource "aws_lb_target_group" "web" {
  name                 = "${var.project}-web-tg"
  port                 = 80
  protocol             = "HTTP"
  vpc_id               = aws_vpc.main.id
  deregistration_delay = 30

  health_check {
    path                = "/healthz"
    matcher             = "200"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# Requests without CloudFront's secret header are refused, so nobody can
# bypass CloudFront by calling the ALB's DNS name directly.
resource "aws_lb_listener" "web_http" {
  load_balancer_arn = aws_lb.web.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Forbidden"
      status_code  = "403"
    }
  }
}

resource "aws_lb_listener_rule" "from_cloudfront" {
  listener_arn = aws_lb_listener.web_http.arn
  priority     = 1

  condition {
    http_header {
      http_header_name = "X-Origin-Verify"
      values           = [random_password.origin_secret.result]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

resource "aws_lb" "app" {
  name                       = "${var.project}-app-alb"
  load_balancer_type         = "application"
  internal                   = true
  security_groups            = [aws_security_group.alb_internal.id]
  subnets                    = aws_subnet.private_app[*].id
  drop_invalid_header_fields = true
  tags                       = { Name = "${var.project}-app-alb-internal" }
}

resource "aws_lb_target_group" "app" {
  name                 = "${var.project}-app-tg"
  port                 = 5000
  protocol             = "HTTP"
  vpc_id               = aws_vpc.main.id
  deregistration_delay = 30

  health_check {
    path                = "/api/health"
    matcher             = "200"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "app_http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}
