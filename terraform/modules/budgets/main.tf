# Module: budgets
# Creates an SNS topic (+ email subscription) and two AWS Budgets:
#   1. Monthly account-wide budget with 80 % actual + 100 % forecasted alerts
#   2. EC2-scoped budget at 60 % of the monthly limit

resource "aws_sns_topic" "alerts" {
  name              = "finops-budget-alerts-${var.suffix}"
  kms_master_key_id = "alias/aws/sns"
  tags              = var.common_tags
}

resource "aws_sns_topic_policy" "budgets_publish" {
  arn = aws_sns_topic.alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowBudgetsPublish"
        Effect = "Allow"
        Principal = { Service = "budgets.amazonaws.com" }
        Action   = "SNS:Publish"
        Resource = aws_sns_topic.alerts.arn
        Condition = {
          StringEquals = { "aws:SourceAccount" = var.account_id }
        }
      },
      {
        Sid    = "AllowCostAnomalyPublish"
        Effect = "Allow"
        Principal = { Service = "costalerts.amazonaws.com" }
        Action   = "SNS:Publish"
        Resource = aws_sns_topic.alerts.arn
      }
    ]
  })
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_budgets_budget" "monthly" {
  name         = "finops-monthly-${var.environment}-${var.suffix}"
  budget_type  = "COST"
  limit_amount = var.limit_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 80
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.alerts.arn]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_sns_topic_arns = [aws_sns_topic.alerts.arn]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.alerts.arn]
  }

  tags = var.common_tags
}

resource "aws_budgets_budget" "ec2" {
  name         = "finops-ec2-${var.environment}-${var.suffix}"
  budget_type  = "COST"
  limit_amount = tostring(tonumber(var.limit_usd) * 0.6)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "Service"
    values = ["Amazon Elastic Compute Cloud - Compute"]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 90
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_sns_topic_arns = [aws_sns_topic.alerts.arn]
  }

  tags = var.common_tags
}

# ── Cost Anomaly Detection ─────────────────────────────────────────────────────
# Detects unexpected spend spikes per AWS service — fires before a budget threshold
# is ever crossed, giving earlier warning than budget alerts alone.
resource "aws_ce_anomaly_monitor" "service" {
  name              = "finops-service-monitor-${var.suffix}"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"
  tags              = var.common_tags
}

resource "aws_ce_anomaly_subscription" "alert" {
  name      = "finops-anomaly-sub-${var.suffix}"
  frequency = "IMMEDIATE"

  monitor_arn_list = [aws_ce_anomaly_monitor.service.arn]

  subscriber {
    type    = "SNS"
    address = aws_sns_topic.alerts.arn
  }

  # Alert when the anomaly's total dollar impact reaches $5 — appropriate for a $50/mo budget.
  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      values        = ["5"]
      match_options = ["GREATER_THAN_OR_EQUAL"]
    }
  }

  tags = var.common_tags
}
