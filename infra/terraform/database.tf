# ------------------------------------------------------- DATABASE, REGISTRY, SECRETS

# --- Amazon ECR: one private repository per tier
resource "aws_ecr_repository" "web" {
  name                 = "${var.project}-web"
  image_tag_mutability = "IMMUTABLE" # a released tag (git SHA) can never be overwritten
  force_delete         = true        # lets `terraform destroy` remove repos that still hold images

  image_scanning_configuration {
    scan_on_push = true # basic vulnerability scan of every pushed image
  }
}

resource "aws_ecr_repository" "app" {
  name                 = "${var.project}-app"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

# Keep only the 10 newest images per repository (storage cost control)
resource "aws_ecr_lifecycle_policy" "keep_recent" {
  for_each   = { web = aws_ecr_repository.web.name, app = aws_ecr_repository.app.name }
  repository = each.value
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 10 }
      action       = { type = "expire" }
    }]
  })
}

# --- Release pointers: the pipeline writes the git SHA here, instances read it at boot.
resource "aws_ssm_parameter" "image_tag" {
  for_each = toset(["web", "app"])
  name     = "/${var.project}/${each.key}/image_tag"
  type     = "String"
  value    = "not-built-yet" # the pipeline writes the first git SHA here

  lifecycle {
    ignore_changes = [value] # owned by the CI/CD pipeline after creation
  }
}

# --- Database credentials: generated here, stored only in Secrets Manager
resource "random_password" "db" {
  length           = 24
  special          = true
  override_special = "!#%^*-_=+" # characters RDS accepts in a master password
}

resource "aws_secretsmanager_secret" "db" {
  name                    = "${var.project}/db-credentials"
  description             = "RDS MySQL credentials for the app tier"
  recovery_window_in_days = 0 # immediate delete on destroy, so a redeploy can reuse the name
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db.result
    host     = aws_db_instance.mysql.address
    port     = aws_db_instance.mysql.port
    dbname   = var.db_name
  })
}

# --- Amazon RDS for MySQL in the isolated DB subnets
resource "aws_db_subnet_group" "db" {
  name       = "${var.project}-db-subnets"
  subnet_ids = aws_subnet.private_db[*].id
  tags       = { Name = "${var.project}-db-subnets" }
}

# Encryption in transit: the server refuses any connection that is not TLS.
# require_secure_transport is a dynamic parameter, so no reboot is needed.
resource "aws_db_parameter_group" "mysql" {
  name        = "${var.project}-mysql84"
  family      = "mysql8.4"
  description = "Force TLS for all client connections"

  parameter {
    name  = "require_secure_transport"
    value = "1"
  }
}

resource "aws_db_instance" "mysql" {
  identifier = "${var.project}-mysql"
  engine     = "mysql"
  # 8.4 LTS: MySQL 8.0 left RDS standard support on 2026-07-31, and new 8.0
  # instances would be billed for RDS Extended Support.
  engine_version       = "8.4"
  instance_class       = var.db_instance_class
  parameter_group_name = aws_db_parameter_group.mysql.name

  allocated_storage     = 20
  max_allocated_storage = 50 # storage autoscaling
  storage_type          = "gp3"
  storage_encrypted     = true # encryption at rest (AWS-managed KMS key)

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.db.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = var.db_multi_az

  backup_retention_period = 1
  skip_final_snapshot     = true  # lab setting; production would keep a final snapshot
  deletion_protection     = false # lab setting
  apply_immediately       = true

  enabled_cloudwatch_logs_exports = ["error", "slowquery"]

  tags = { Name = "${var.project}-mysql" }
}
