# Module: tagging_governance
# Enforces CostCenter tag on EC2 instances and EBS volumes using:
#   - AWS Config recorder + delivery channel + required-tags managed rules
#   - CloudWatch Event Rule → SNS to alert on NON_COMPLIANT resources

data "aws_caller_identity" "current" {}

# ── S3 bucket for Config snapshots ───────────────────────────────────────────
resource "aws_s3_bucket" "config" {
  bucket        = "finops-config-${data.aws_caller_identity.current.account_id}-${var.suffix}"
  force_destroy = true
  tags          = var.common_tags
}

resource "aws_s3_bucket_versioning" "config" {
  bucket = aws_s3_bucket.config.id
  versioning_configuration { status = "Enabled" }
}

# Expire Config snapshots after 90 days; purge old versions after 30 days.
# Prevents unbounded storage cost — ironic to skip in a FinOps project.
resource "aws_s3_bucket_lifecycle_configuration" "config" {
  bucket = aws_s3_bucket.config.id
  depends_on = [aws_s3_bucket_versioning.config]

  rule {
    id     = "expire-config-snapshots"
    status = "Enabled"
    filter {}

    expiration {
      days = 90
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "config" {
  bucket = aws_s3_bucket.config.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "config" {
  bucket                  = aws_s3_bucket.config.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "config" {
  bucket = aws_s3_bucket.config.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSConfigBucketPermissionsCheck"
        Effect = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.config.arn
        Condition = {
          StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        }
      },
      {
        Sid    = "AWSConfigBucketDelivery"
        Effect = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.config.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/Config/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"      = "bucket-owner-full-control"
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

# ── IAM role for Config ───────────────────────────────────────────────────────
resource "aws_iam_role" "config" {
  name = "finops-config-role-${var.suffix}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "config.amazonaws.com" }
    }]
  })
  tags = var.common_tags
}

resource "aws_iam_role_policy_attachment" "config" {
  role       = aws_iam_role.config.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

# ── Config Recorder ───────────────────────────────────────────────────────────
resource "aws_config_configuration_recorder" "main" {
  name     = "finops-recorder-${var.suffix}"
  role_arn = aws_iam_role.config.arn

  recording_group {
    all_supported                 = false
    include_global_resource_types = false
    resource_types = [
      "AWS::EC2::Instance",
      "AWS::EC2::Volume",
      "AWS::EC2::EIP",
      "AWS::EC2::NetworkInterface",
    ]
  }
}

resource "aws_config_delivery_channel" "main" {
  name           = "finops-channel-${var.suffix}"
  s3_bucket_name = aws_s3_bucket.config.bucket
  depends_on     = [aws_config_configuration_recorder.main]
}

resource "aws_config_configuration_recorder_status" "main" {
  name       = aws_config_configuration_recorder.main.name
  is_enabled = true
  depends_on = [aws_config_delivery_channel.main]
}

# ── Config Rules ──────────────────────────────────────────────────────────────
resource "aws_config_config_rule" "ec2_costcenter" {
  name        = "require-costcenter-ec2"
  description = "EC2 instances must have all four mandatory cost tags"

  source {
    owner             = "AWS"
    source_identifier = "REQUIRED_TAGS"
  }

  input_parameters = jsonencode({
    tag1Key = "CostCenter"
    tag2Key = "Environment"
    tag3Key = "ManagedBy"
    tag4Key = "Project"
  })

  scope {
    compliance_resource_types = ["AWS::EC2::Instance"]
  }

  depends_on = [aws_config_configuration_recorder_status.main]
  tags       = var.common_tags
}

resource "aws_config_config_rule" "ebs_costcenter" {
  name        = "require-costcenter-ebs"
  description = "EBS volumes must have all four mandatory cost tags"

  source {
    owner             = "AWS"
    source_identifier = "REQUIRED_TAGS"
  }

  input_parameters = jsonencode({
    tag1Key = "CostCenter"
    tag2Key = "Environment"
    tag3Key = "ManagedBy"
    tag4Key = "Project"
  })

  scope {
    compliance_resource_types = ["AWS::EC2::Volume"]
  }

  depends_on = [aws_config_configuration_recorder_status.main]
  tags       = var.common_tags
}

# EIPs are blocked by SCP without CostCenter but weren't validated by Config — gap now closed.
resource "aws_config_config_rule" "eip_costcenter" {
  name        = "require-costcenter-eip"
  description = "Elastic IPs must have a CostCenter tag"

  source {
    owner             = "AWS"
    source_identifier = "REQUIRED_TAGS"
  }

  input_parameters = jsonencode({ tag1Key = "CostCenter" })

  scope {
    compliance_resource_types = ["AWS::EC2::EIP"]
  }

  depends_on = [aws_config_configuration_recorder_status.main]
  tags       = var.common_tags
}

# ── Alert on non-compliance via EventBridge → SNS ─────────────────────────────
resource "aws_sns_topic" "compliance" {
  name              = "finops-compliance-${var.suffix}"
  kms_master_key_id = "alias/aws/sns"
  tags              = var.common_tags
}

# Without this policy EventBridge cannot publish — the existing event target would silently fail.
resource "aws_sns_topic_policy" "compliance" {
  arn = aws_sns_topic.compliance.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowEventBridgePublish"
      Effect = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action   = "SNS:Publish"
      Resource = aws_sns_topic.compliance.arn
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })
}

resource "aws_sns_topic_subscription" "compliance_email" {
  topic_arn = aws_sns_topic.compliance.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_event_rule" "noncompliant" {
  name        = "finops-noncompliant-${var.suffix}"
  description = "Fires when Config flags a resource NON_COMPLIANT"
  event_pattern = jsonencode({
    source      = ["aws.config"]
    detail-type = ["Config Rules Compliance Change"]
    detail = {
      newEvaluationResult = { complianceType = ["NON_COMPLIANT"] }
    }
  })
  tags = var.common_tags
}

resource "aws_cloudwatch_event_target" "noncompliant_sns" {
  rule      = aws_cloudwatch_event_rule.noncompliant.name
  target_id = "SendToSNS"
  arn       = aws_sns_topic.compliance.arn
}
