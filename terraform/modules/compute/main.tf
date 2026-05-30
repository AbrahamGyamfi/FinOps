# Module: compute
# Deploys: VPC → public subnets → ALB → ASG (Mixed Instances Policy)
# On-Demand base + Graviton Spot scale-out achieves ~70-80% compute cost reduction
# vs x86 On-Demand. AL2023 replaces the EOL Amazon Linux 2.

locals {
  azs        = ["eu-central-1a", "eu-central-1b"]
  al2023_id  = "ami-0d3afa848fc8b043e" # AL2023 ARM64, eu-central-1
}

# ── VPC ───────────────────────────────────────────────────────────────────────
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = merge(var.common_tags, { Name = "finops-app-vpc-${var.suffix}" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.common_tags, { Name = "finops-igw-${var.suffix}" })
}

resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true
  tags                    = merge(var.common_tags, { Name = "finops-pub-${count.index}-${var.suffix}" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(var.common_tags, { Name = "finops-pub-rt-${var.suffix}" })
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ── Security Groups ───────────────────────────────────────────────────────────
resource "aws_security_group" "alb" {
  name        = "finops-alb-sg-${var.suffix}"
  description = "ALB: accept HTTP from internet"
  vpc_id      = aws_vpc.this.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.common_tags, { Name = "finops-alb-sg-${var.suffix}" })
}

resource "aws_security_group" "app" {
  name        = "finops-app-sg-${var.suffix}"
  description = "App: only accept traffic from ALB"
  vpc_id      = aws_vpc.this.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.common_tags, { Name = "finops-app-sg-${var.suffix}" })
}

# ── ALB ───────────────────────────────────────────────────────────────────────
resource "aws_lb" "this" {
  name               = "finops-alb-${var.suffix}"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
  tags               = merge(var.common_tags, { Name = "finops-alb-${var.suffix}" })
}

resource "aws_lb_target_group" "this" {
  name     = "finops-tg-${var.suffix}"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.this.id

  health_check {
    path                = var.health_check_path
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
  }

  tags = var.common_tags
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

# ── IAM Instance Profile ──────────────────────────────────────────────────────
resource "aws_iam_role" "ec2" {
  name = "finops-ec2-role-${var.suffix}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "finops-profile-${var.suffix}"
  role = aws_iam_role.ec2.name
}

# ── Launch Template ───────────────────────────────────────────────────────────
resource "aws_launch_template" "app" {
  name_prefix   = "finops-lt-"
  image_id      = local.al2023_id
  instance_type = var.base_instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.ec2.arn
  }

  vpc_security_group_ids               = [aws_security_group.app.id]
  instance_initiated_shutdown_behavior = "terminate"

  user_data = base64encode(<<-USERDATA
    #!/bin/bash
    yum update -y && yum install -y python3
    python3 -c "
    import http.server, socketserver
    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'OK')
        def log_message(self, *a): pass
    with socketserver.TCPServer(('', 80), H) as s: s.serve_forever()
    " &
  USERDATA
  )

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.root_volume_size_gb
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  monitoring {
    enabled = true
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.common_tags, { Name = "finops-app-${var.suffix}" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(var.common_tags, { Name = "finops-vol-${var.suffix}" })
  }

  tags = var.common_tags
}

# ── Auto Scaling Group — Mixed Instances Policy ───────────────────────────────
resource "aws_autoscaling_group" "this" {
  name                      = "finops-asg-${var.suffix}"
  vpc_zone_identifier       = aws_subnet.public[*].id
  target_group_arns         = [aws_lb_target_group.this.arn]
  health_check_type         = "ELB"
  health_check_grace_period = var.health_check_grace_period

  min_size         = var.asg_min_size
  max_size         = var.asg_max_size
  desired_capacity = var.asg_desired_capacity

  enabled_metrics = [
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
    "GroupPendingInstances",
    "GroupTerminatingInstances",
    "GroupTotalInstances",
    "GroupMinSize",
    "GroupMaxSize",
  ]

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = var.min_healthy_percentage
    }
  }

  mixed_instances_policy {
    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.app.id
        version            = "$Latest"
      }

      # Graviton2/3 ARM64 pool — ~20% cheaper than x86 equivalent, same AMI
      override {
        instance_type     = "t4g.small"
        weighted_capacity = "1"
      }
      override {
        instance_type     = "t4g.medium"
        weighted_capacity = "2"
      }
      override {
        instance_type     = "c7g.medium"
        weighted_capacity = "2"
      }
      override {
        instance_type     = "m7g.medium"
        weighted_capacity = "2"
      }
    }

    instances_distribution {
      on_demand_base_capacity                  = var.on_demand_base_capacity
      on_demand_percentage_above_base_capacity = var.on_demand_percentage_above_base
      # capacity-optimized-prioritized picks the pool with most available Spot
      # capacity. spot_instance_pools is omitted — it only applies to lowest-price.
      spot_allocation_strategy = "capacity-optimized-prioritized"
    }
  }

  tag {
    key                 = "CostCenter"
    value               = var.cost_center
    propagate_at_launch = true
  }

  tag {
    key                 = "Name"
    value               = "finops-app-${var.suffix}"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ── Target Tracking Scaling Policy ───────────────────────────────────────────
resource "aws_autoscaling_policy" "cpu_tracking" {
  name                   = "finops-cpu-track-${var.suffix}"
  autoscaling_group_name = aws_autoscaling_group.this.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = var.cpu_target_pct
  }
}

# ── Scheduled Scaling (sandbox cost saving ~65%) ──────────────────────────────
# When enabled, collapses the ASG to the On-Demand floor overnight (20:00 UTC)
# and on weekends, then restores normal sizing on weekday mornings (08:00 UTC).
resource "aws_autoscaling_schedule" "scale_down_evening" {
  count                  = var.enable_scheduled_scaling ? 1 : 0
  scheduled_action_name  = "finops-scale-down-evening"
  autoscaling_group_name = aws_autoscaling_group.this.name
  recurrence             = "0 20 * * MON-FRI"
  min_size               = var.on_demand_base_capacity
  max_size               = var.on_demand_base_capacity
  desired_capacity       = var.on_demand_base_capacity
}

resource "aws_autoscaling_schedule" "scale_up_morning" {
  count                  = var.enable_scheduled_scaling ? 1 : 0
  scheduled_action_name  = "finops-scale-up-morning"
  autoscaling_group_name = aws_autoscaling_group.this.name
  recurrence             = "0 8 * * MON-FRI"
  min_size               = var.asg_min_size
  max_size               = var.asg_max_size
  desired_capacity       = var.asg_desired_capacity
}

resource "aws_autoscaling_schedule" "scale_down_weekend" {
  count                  = var.enable_scheduled_scaling ? 1 : 0
  scheduled_action_name  = "finops-scale-down-weekend"
  autoscaling_group_name = aws_autoscaling_group.this.name
  recurrence             = "0 0 * * SAT"
  min_size               = var.on_demand_base_capacity
  max_size               = var.on_demand_base_capacity
  desired_capacity       = var.on_demand_base_capacity
}

resource "aws_autoscaling_schedule" "scale_up_monday" {
  count                  = var.enable_scheduled_scaling ? 1 : 0
  scheduled_action_name  = "finops-scale-up-monday"
  autoscaling_group_name = aws_autoscaling_group.this.name
  recurrence             = "0 7 * * MON"
  min_size               = var.asg_min_size
  max_size               = var.asg_max_size
  desired_capacity       = var.asg_desired_capacity
}
