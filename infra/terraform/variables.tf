variable "region" {
  description = "AWS region (AWS Academy Learner Lab allows us-east-1 and us-west-2)"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Name prefix for all resources. The CI/CD pipeline assumes 'cea'."
  type        = string
  default     = "cea"
}

variable "vpc_cidr" {
  description = "VPC address range. /16 gives 65,536 addresses, room for many /24 subnets."
  type        = string
  default     = "10.0.0.0/16"
}

variable "instance_type" {
  description = "EC2 type for web and app container hosts"
  type        = string
  default     = "t3.micro"
}

variable "web_min" {
  type    = number
  default = 2
}

variable "web_max" {
  type    = number
  default = 4
}

variable "app_min" {
  type    = number
  default = 2
}

variable "app_max" {
  type    = number
  default = 4
}

variable "cpu_target" {
  description = "Target average CPU % for the auto scaling policies"
  type        = number
  default     = 50
}

variable "db_instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "db_multi_az" {
  description = "true = synchronous standby in a second AZ with automatic failover (about double the DB cost)"
  type        = bool
  default     = false
}

variable "db_name" {
  type    = string
  default = "tasksdb"
}

variable "db_username" {
  type    = string
  default = "appadmin"
}

variable "existing_instance_profile" {
  description = "Leave empty to let Terraform create a least-privilege role. AWS Academy Learner Lab cannot create IAM roles: set this to \"LabInstanceProfile\"."
  type        = string
  default     = ""
}

variable "github_repo" {
  description = "GitHub repository allowed to deploy, as \"owner/name\". Empty = no OIDC deploy role is created."
  type        = string
  default     = ""

  validation {
    condition     = var.github_repo == "" || can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repo))
    error_message = "github_repo must look like \"owner/name\"."
  }
}

variable "log_retention_days" {
  type    = number
  default = 7
}

variable "alarm_email" {
  description = "Optional e-mail for CloudWatch alarm notifications (confirm the SNS e-mail you receive)"
  type        = string
  default     = ""
}
