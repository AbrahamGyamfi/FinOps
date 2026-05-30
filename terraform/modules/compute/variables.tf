variable "suffix" { type = string }
variable "cost_center" { type = string }

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "asg_min_size" {
  type    = number
  default = 1
}

variable "asg_max_size" {
  type    = number
  default = 6
}

variable "asg_desired_capacity" {
  type    = number
  default = 2
}

variable "on_demand_base_capacity" {
  type    = number
  default = 1
}

variable "on_demand_percentage_above_base" {
  type    = number
  default = 20
}

variable "base_instance_type" {
  description = "Default instance type in the launch template (must be ARM64 / Graviton)"
  type        = string
  default     = "t4g.small"
}

variable "root_volume_size_gb" {
  type    = number
  default = 20
}

variable "health_check_grace_period" {
  type    = number
  default = 120
}

variable "min_healthy_percentage" {
  type    = number
  default = 50
}

variable "cpu_target_pct" {
  type    = number
  default = 60
}

variable "health_check_path" {
  type    = string
  default = "/health"
}

variable "enable_scheduled_scaling" {
  description = "Scale the ASG to minimum overnight (20:00–08:00 UTC) and all weekend to cut sandbox compute costs by ~65%"
  type        = bool
  default     = false
}

variable "common_tags" {
  type    = map(string)
  default = {}
}
