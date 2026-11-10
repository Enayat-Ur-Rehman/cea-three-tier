# ---------------------------------------------------------------- SECURITY GROUPS
# One security group per tier. Each tier accepts traffic only from the tier
# directly in front of it (least privilege), referenced by security-group ID
# rather than by IP range, so rules stay correct when instances are replaced.
#
#   Internet --80--> alb-public --80--> web --80--> alb-internal --5000--> app --3306--> db
#
# Egress is restricted too: hosts may only call AWS APIs over HTTPS (443) and
# the next tier. No SSH port is open anywhere; admin access is via SSM Session Manager.

resource "aws_security_group" "alb_public" {
  name        = "${var.project}-sg-alb-public"
  description = "Public ALB - HTTP from the internet"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project}-sg-alb-public" }
}

resource "aws_security_group" "web" {
  name        = "${var.project}-sg-web"
  description = "Web tier hosts - only from the public ALB"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project}-sg-web" }
}

resource "aws_security_group" "alb_internal" {
  name        = "${var.project}-sg-alb-internal"
  description = "Internal ALB - only from web tier"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project}-sg-alb-internal" }
}

resource "aws_security_group" "app" {
  name        = "${var.project}-sg-app"
  description = "App tier hosts - only from the internal ALB"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project}-sg-app" }
}

resource "aws_security_group" "db" {
  name        = "${var.project}-sg-db"
  description = "RDS MySQL - only from app tier"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project}-sg-db" }
}

# --- Public ALB
# Only CloudFront's origin-facing IP ranges (an AWS-managed prefix list).
# The list has about 55 entries and counts that much toward the 60-rule limit,
# so this group holds no other ingress rule.
resource "aws_vpc_security_group_ingress_rule" "alb_public_http" {
  security_group_id = aws_security_group.alb_public.id
  description       = "HTTP from CloudFront only"
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront.id
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_egress_rule" "alb_public_to_web" {
  security_group_id            = aws_security_group.alb_public.id
  description                  = "Forward to web hosts"
  referenced_security_group_id = aws_security_group.web.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
}

# --- Web tier
resource "aws_vpc_security_group_ingress_rule" "web_from_alb" {
  security_group_id            = aws_security_group.web.id
  description                  = "HTTP from public ALB only"
  referenced_security_group_id = aws_security_group.alb_public.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
}

resource "aws_vpc_security_group_egress_rule" "web_https" {
  security_group_id = aws_security_group.web.id
  description       = "HTTPS to AWS APIs (ECR, SSM, CloudWatch) and OS packages"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "web_to_internal_alb" {
  security_group_id            = aws_security_group.web.id
  description                  = "API calls to internal ALB"
  referenced_security_group_id = aws_security_group.alb_internal.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
}

# --- Internal ALB
resource "aws_vpc_security_group_ingress_rule" "alb_internal_from_web" {
  security_group_id            = aws_security_group.alb_internal.id
  description                  = "HTTP from web tier only"
  referenced_security_group_id = aws_security_group.web.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
}

resource "aws_vpc_security_group_egress_rule" "alb_internal_to_app" {
  security_group_id            = aws_security_group.alb_internal.id
  description                  = "Forward to app hosts"
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 5000
  to_port                      = 5000
}

# --- App tier
resource "aws_vpc_security_group_ingress_rule" "app_from_internal_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "Gunicorn port from internal ALB only"
  referenced_security_group_id = aws_security_group.alb_internal.id
  ip_protocol                  = "tcp"
  from_port                    = 5000
  to_port                      = 5000
}

resource "aws_vpc_security_group_egress_rule" "app_https" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS via NAT to AWS APIs (ECR, Secrets Manager, SSM, CloudWatch)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "app_to_db" {
  security_group_id            = aws_security_group.app.id
  description                  = "MySQL to RDS"
  referenced_security_group_id = aws_security_group.db.id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
}

# --- Database tier. No egress rules: replies still flow because security groups are stateful.
resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  description                  = "MySQL from app tier only"
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
}
