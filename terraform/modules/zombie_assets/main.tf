# Module: zombie_assets
# Creates intentionally wasteful resources that simulate a neglected AWS account:
#   - 3 unattached EBS volumes (gp3, st1, io2)
#   - 2 unassociated Elastic IPs
#   - 1 idle m5.xlarge EC2 instance (no workload, 0% CPU)
# These exist only to be detected by the audit/garbage-collector scripts.

locals {
  azs      = ["eu-central-1a", "eu-central-1b"]
  amzn2_id = "ami-0af964531014e9a60" # Amazon Linux 2 x86_64, eu-central-1
}

# ── Unattached EBS Volumes ────────────────────────────────────────────────────
resource "aws_ebs_volume" "gp3" {
  availability_zone = local.azs[0]
  size              = 50
  type              = "gp3"
  tags = merge(var.common_tags, { Name = "zombie-ebs-gp3-${var.suffix}" })
}

resource "aws_ebs_volume" "st1" {
  availability_zone = local.azs[0]
  size              = 125
  type              = "st1"
  tags = merge(var.common_tags, { Name = "zombie-ebs-st1-${var.suffix}" })
}

resource "aws_ebs_volume" "io2" {
  availability_zone = local.azs[0]
  size              = 100
  type              = "io2"
  iops              = 3000
  tags = merge(var.common_tags, { Name = "zombie-ebs-io2-${var.suffix}" })
}

# ── Unassociated Elastic IPs ──────────────────────────────────────────────────
resource "aws_eip" "one" {
  domain = "vpc"
  tags   = merge(var.common_tags, { Name = "zombie-eip-1-${var.suffix}" })
}

resource "aws_eip" "two" {
  domain = "vpc"
  tags   = merge(var.common_tags, { Name = "zombie-eip-2-${var.suffix}" })
}

# ── Idle Large EC2 Instance ───────────────────────────────────────────────────
resource "aws_vpc" "zombie" {
  cidr_block = "172.31.200.0/24"
  tags       = merge(var.common_tags, { Name = "zombie-vpc-${var.suffix}" })
}

resource "aws_subnet" "zombie" {
  vpc_id            = aws_vpc.zombie.id
  cidr_block        = "172.31.200.0/25"
  availability_zone = local.azs[0]
  tags              = merge(var.common_tags, { Name = "zombie-subnet-${var.suffix}" })
}

resource "aws_security_group" "zombie" {
  name        = "zombie-idle-sg-${var.suffix}"
  description = "No traffic - idle instance"
  vpc_id      = aws_vpc.zombie.id
  tags        = merge(var.common_tags, { Name = "zombie-idle-sg-${var.suffix}" })
}

resource "aws_instance" "idle" {
  ami                    = local.amzn2_id
  instance_type          = "m5.xlarge"
  subnet_id              = aws_subnet.zombie.id
  vpc_security_group_ids = [aws_security_group.zombie.id]

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    encrypted             = true
    delete_on_termination = true
  }

  # Deliberately missing CostCenter tag to trigger Config Rule
  tags = merge(var.common_tags, { Name = "idle-large-${var.suffix}" })
}
