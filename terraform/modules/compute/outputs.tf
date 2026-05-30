output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "asg_name" {
  value = aws_autoscaling_group.this.name
}

output "launch_template_id" {
  value = aws_launch_template.app.id
}

# ALB ARN suffix used as the CloudWatch dimension value for ApplicationELB metrics
output "alb_arn_suffix" {
  value = element(split(":loadbalancer/", aws_lb.this.arn), 1)
}
