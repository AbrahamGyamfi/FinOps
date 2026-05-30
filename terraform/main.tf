# =============================================================================
# ROOT MODULE — wires all child modules together
# Usage:
#   terraform init
#   terraform plan -var="budget_alert_email=you@example.com"
#   terraform apply -var="budget_alert_email=you@example.com"
# =============================================================================

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "FinOps-CostDetective"
      ManagedBy = "Terraform"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "random_id" "suffix" { byte_length = 4 }

locals {
  suffix = random_id.suffix.hex
  common_tags = {
    Environment = var.environment
    CostCenter  = var.cost_center
    Project     = "FinOps-CostDetective"
    ManagedBy   = "Terraform"
  }
}

# ── Module: Zombie Assets (audit sandbox only) ─────────────────────────────────
module "zombie_assets" {
  source  = "./modules/zombie_assets"
  suffix  = local.suffix
  common_tags = local.common_tags
}

# ── Module: Budgets & Alerting ─────────────────────────────────────────────────
module "budgets" {
  source      = "./modules/budgets"
  suffix      = local.suffix
  account_id  = data.aws_caller_identity.current.account_id
  environment = var.environment
  alert_email = var.budget_alert_email
  limit_usd   = var.budget_limit_usd
  common_tags = local.common_tags
}

# ── Module: Tagging Governance ────────────────────────────────────────────────
module "tagging_governance" {
  source      = "./modules/tagging_governance"
  suffix      = local.suffix
  alert_email = var.budget_alert_email
  common_tags = local.common_tags
}

# ── Module: Compute ──────────────────────────────────────────────────────────
module "compute" {
  source                          = "./modules/compute"
  suffix                          = local.suffix
  cost_center                     = var.cost_center
  vpc_cidr                        = var.vpc_cidr
  public_subnet_cidrs             = var.public_subnet_cidrs
  asg_min_size                    = var.asg_min_size
  asg_max_size                    = var.asg_max_size
  asg_desired_capacity            = var.asg_desired_capacity
  on_demand_base_capacity         = var.on_demand_base_capacity
  on_demand_percentage_above_base = var.on_demand_percentage_above_base
  base_instance_type              = var.base_instance_type
  root_volume_size_gb             = var.root_volume_size_gb
  health_check_grace_period       = var.health_check_grace_period
  min_healthy_percentage          = var.min_healthy_percentage
  cpu_target_pct                  = var.cpu_target_pct
  health_check_path               = var.health_check_path
  enable_scheduled_scaling        = var.enable_scheduled_scaling
  common_tags                     = local.common_tags
}

# ── CloudWatch Dashboard ──────────────────────────────────────────────────────
resource "aws_cloudwatch_dashboard" "finops" {
  dashboard_name = "FinOps-CostDetective-${local.suffix}"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "ASG — Spot vs On-Demand Instances"
          view    = "timeSeries"
          stacked = true
          metrics = [
            ["AWS/AutoScaling", "GroupOnDemandInstances", "AutoScalingGroupName", module.compute.asg_name, { label = "On-Demand", color = "#d62728" }],
            ["AWS/AutoScaling", "GroupSpotInstances",     "AutoScalingGroupName", module.compute.asg_name, { label = "Spot",      color = "#2ca02c" }],
          ]
          period = 300
          stat   = "Average"
          region = var.aws_region
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "ASG — CPU Utilization vs 60% Target"
          view    = "timeSeries"
          metrics = [
            ["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", module.compute.asg_name, { label = "CPU %" }]
          ]
          annotations = {
            horizontal = [{ value = 60, label = "Scale-Out Target (60%)", color = "#ff7f0e", fill = "above" }]
          }
          yAxis  = { left = { min = 0, max = 100 } }
          period = 60
          stat   = "Average"
          region = var.aws_region
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "ALB — Request Count (5-min sum)"
          view    = "timeSeries"
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", module.compute.alb_arn_suffix, { stat = "Sum", label = "Requests" }]
          ]
          period = 300
          region = var.aws_region
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "ALB — 5XX Error Count"
          view    = "timeSeries"
          metrics = [
            ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", module.compute.alb_arn_suffix, { stat = "Sum", label = "5XX", color = "#d62728" }]
          ]
          period = 300
          region = var.aws_region
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 24
        height = 6
        properties = {
          title   = "ASG — Desired vs In-Service Capacity"
          view    = "timeSeries"
          metrics = [
            ["AWS/AutoScaling", "GroupDesiredCapacity",    "AutoScalingGroupName", module.compute.asg_name, { label = "Desired" }],
            ["AWS/AutoScaling", "GroupInServiceInstances", "AutoScalingGroupName", module.compute.asg_name, { label = "In Service" }],
          ]
          period = 300
          stat   = "Average"
          region = var.aws_region
        }
      }
    ]
  })
}

