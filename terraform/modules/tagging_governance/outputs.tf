output "config_bucket" {
  value = aws_s3_bucket.config.bucket
}

output "compliance_sns_arn" {
  value = aws_sns_topic.compliance.arn
}

output "ec2_rule_name" {
  value = aws_config_config_rule.ec2_costcenter.name
}

output "ebs_rule_name" {
  value = aws_config_config_rule.ebs_costcenter.name
}

output "eip_rule_name" {
  value = aws_config_config_rule.eip_costcenter.name
}

output "compliance_sns_topic_name" {
  value = aws_sns_topic.compliance.name
}
