output "sns_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "monthly_budget_name" {
  value = aws_budgets_budget.monthly.name
}

output "ec2_budget_name" {
  value = aws_budgets_budget.ec2.name
}

output "anomaly_monitor_arn" {
  value = aws_ce_anomaly_monitor.service.arn
}
