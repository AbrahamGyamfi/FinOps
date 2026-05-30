# ── General ───────────────────────────────────────────────────────────────────
variable "aws_region" {
  description = "AWS region to deploy all resources"
  type        = string
  default     = "eu-central-1"
}

variable "environment" {
  description = "Deployment environment label (sandbox | staging | prod)"
  type        = string
  default     = "sandbox"
}

variable "cost_center" {
  description = "CostCenter tag value applied to all governed resources"
  type        = string
  default     = "finops-audit"
}

# ── Budgets ───────────────────────────────────────────────────────────────────
variable "budget_alert_email" {
  description = "Email address that receives AWS Budget breach notifications"
  type        = string
  # Set via -var flag or terraform.tfvars — never hard-code in VCS
}

variable "budget_limit_usd" {
  description = "Monthly spend threshold (USD) that triggers a forecasted-cost alert"
  type        = string
  default     = "50"
}

# ── Networking ────────────────────────────────────────────────────────────────
variable "vpc_cidr" {
  description = "CIDR block for the application VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for the public subnets (one per AZ)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

# ── ASG sizing ────────────────────────────────────────────────────────────────
variable "asg_min_size" {
  description = "Minimum number of instances in the ASG"
  type        = number
  default     = 1
}

variable "asg_max_size" {
  description = "Maximum number of instances in the ASG"
  type        = number
  default     = 6
}

variable "asg_desired_capacity" {
  description = "Desired number of instances at steady state"
  type        = number
  default     = 2
}

variable "on_demand_base_capacity" {
  description = "Number of On-Demand instances always kept running (reliability floor)"
  type        = number
  default     = 1
}

variable "on_demand_percentage_above_base" {
  description = "Percentage of scale-out capacity to run as On-Demand (remainder is Spot)"
  type        = number
  default     = 20
}

# ── Compute ───────────────────────────────────────────────────────────────────
variable "base_instance_type" {
  description = "Default instance type in the launch template"
  type        = string
  default     = "t3.small"
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GiB"
  type        = number
  default     = 20
}

# ── Scaling policy ────────────────────────────────────────────────────────────
variable "cpu_target_pct" {
  description = "Target average CPU utilisation (%) for the tracking scaling policy"
  type        = number
  default     = 60
}

variable "min_healthy_percentage" {
  description = "Minimum percentage of healthy instances during a rolling instance refresh"
  type        = number
  default     = 50
}

variable "health_check_grace_period" {
  description = "Seconds the ASG waits before checking instance health after launch"
  type        = number
  default     = 120
}

variable "health_check_path" {
  description = "HTTP path the ALB uses for target health checks"
  type        = string
  default     = "/health"
}

variable "enable_scheduled_scaling" {
  description = "Scale the ASG to the On-Demand floor overnight and on weekends (saves ~65% of sandbox compute hours)"
  type        = bool
  default     = false
}
