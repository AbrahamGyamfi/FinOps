# AWS Cost Optimization — End-to-End Practical Guide

**Author:** Abraham Gyamfi  
**Last updated:** 2026-05-27  
**Environment:** Any AWS account — examples use eu-central-1

---

## Who This Guide Is For

Platform engineers, DevOps engineers, and cloud architects who need to reduce AWS spend without sacrificing reliability. Every technique here is implementable today — no third-party tools required, no AWS Enterprise support needed.

---

## Table of Contents

1. [The Cost Optimization Mindset](#1-the-cost-optimization-mindset)
2. [Step 1 — Gain Visibility](#2-step-1--gain-visibility)
3. [Step 2 — Eliminate Waste (Zombie Assets)](#3-step-2--eliminate-waste-zombie-assets)
4. [Step 3 — Enforce Governance](#4-step-3--enforce-governance)
5. [Step 4 — Right-Size Your Compute](#5-step-4--right-size-your-compute)
6. [Step 5 — Use Spot and Savings Plans](#6-step-5--use-spot-and-savings-plans)
7. [Step 6 — Architect for Cost from Day One](#7-step-6--architect-for-cost-from-day-one)
8. [Step 7 — Set Guardrails and Alerts](#8-step-7--set-guardrails-and-alerts)
9. [Step 8 — Measure and Repeat](#9-step-8--measure-and-repeat)
10. [Quick-Win Checklist](#10-quick-win-checklist)
11. [Common Mistakes to Avoid](#11-common-mistakes-to-avoid)

---

## 1. The Cost Optimization Mindset

Cloud cost optimization is **not a one-time event** — it is an ongoing engineering practice. The three principles that underpin every technique in this guide:

| Principle | What it means in practice |
|---|---|
| **Visibility first** | You cannot optimize what you cannot see. Tag everything. Enable Cost Explorer. Set up dashboards before you touch a resource. |
| **Waste before optimization** | Eliminating idle resources always yields a higher ROI than architectural changes. Run the zombie scan first. |
| **Automate enforcement** | Manual processes rot. Every governance rule should be a Config rule, an SCP, or a script — not a wiki page. |

---

## 2. Step 1 — Gain Visibility

### 2.1 Enable Cost Explorer

```bash
# Enable via CLI (one-time per account)
aws ce put-cost-and-usage-enabled --enabled
```

In the console: `AWS Cost Management → Cost Explorer → Enable Cost Explorer`

Once enabled, you can:
- Break spend down by service, region, tag, or linked account
- See 12 months of historical data
- View daily granularity for the current month
- Forecast spend for the rest of the month

### 2.2 Tag Every Resource

Without tags, Cost Explorer shows "EC2 — $3,400" with no way to know which team or project is responsible. A tagging standard solves this.

**Recommended minimum tag set:**

| Tag | Value example | Purpose |
|---|---|---|
| `CostCenter` | `eng-platform` | Financial allocation |
| `Environment` | `prod` / `staging` / `sandbox` | Separate production from dev cost |
| `Project` | `checkout-service` | Initiative-level showback |
| `ManagedBy` | `Terraform` | Audit trail |

**Apply tags via CLI:**
```bash
aws ec2 create-tags \
  --resources i-0abc123 vol-0def456 \
  --tags Key=CostCenter,Value=eng-platform \
         Key=Environment,Value=prod \
         Key=Project,Value=checkout-service \
         Key=ManagedBy,Value=Terraform \
  --region eu-central-1
```

**Tag all resources at launch** — retrofitting tags to existing infrastructure is painful. Build tagging into your Terraform modules or CloudFormation stacks from day one:

```hcl
# Terraform: apply default tags to every resource in the provider
provider "aws" {
  region = "eu-central-1"
  default_tags {
    tags = {
      ManagedBy   = "Terraform"
      Project     = "my-project"
      Environment = var.environment
    }
  }
}
```

### 2.3 Enable Trusted Advisor (if you have Business/Enterprise support)

`AWS Console → Trusted Advisor → Cost Optimization`

Key checks:
- **Low Utilization Amazon EC2 Instances** — instances below 10% CPU for 14 days
- **Unassociated Elastic IP Addresses** — idle IPs costing $3.60/mo each
- **Underutilized Amazon EBS Volumes** — volumes not attached to any instance
- **Amazon RDS Idle DB Instances** — databases with no connections for 7 days

### 2.4 Set Up a CloudWatch Cost Dashboard

A single dashboard with these three widgets gives you daily awareness:

```
Widget 1: Daily spend (metric: AWS/Billing — EstimatedCharges by ServiceName)
Widget 2: ASG capacity vs Spot % (if you run Auto Scaling Groups)
Widget 3: EC2 average CPU across all instances (alert when consistently low = rightsizing opportunity)
```

---

## 3. Step 2 — Eliminate Waste (Zombie Assets)

This is always your highest-ROI first step. In most inherited AWS accounts, 15–30% of spend is pure waste.

### 3.1 Unattached EBS Volumes

EBS volumes persist after their EC2 instance is terminated. They are billed whether attached or not.

**Find them:**
```bash
aws ec2 describe-volumes \
  --filters Name=status,Values=available \
  --query 'Volumes[*].[VolumeId,VolumeType,Size,AvailabilityZone,CreateTime]' \
  --output table \
  --region eu-central-1
```

**Delete them (after confirming no snapshots are needed):**
```bash
aws ec2 delete-volume --volume-id vol-0abc123 --region eu-central-1
```

**Automate the detection:**
```bash
./scripts/audit_zombie_assets.sh --region eu-central-1
./scripts/garbage_collector.sh   --region eu-central-1 --delete --skip-ec2
```

**Cost impact:** gp3 volumes cost $0.0952/GB/month. A forgotten 500 GB volume = $47.60/month — nearly your entire $50 budget gone to nothing.

### 3.2 Unassociated Elastic IPs

Elastic IPs reserved but not attached to a running instance are charged $0.005/hour = **$3.60/month** each.

**Find them:**
```bash
aws ec2 describe-addresses \
  --query 'Addresses[?AssociationId==null].[AllocationId,PublicIp]' \
  --output table \
  --region eu-central-1
```

**Release them:**
```bash
aws ec2 release-address --allocation-id eipalloc-0abc123 --region eu-central-1
```

### 3.3 Idle EC2 Instances

An m5.xlarge running at 0% CPU for 30 days costs ~$154. Use CloudWatch to find instances with consistently low CPU:

**Find instances with < 5% CPU over 14 days:**
```bash
# List all running instances first
aws ec2 describe-instances \
  --filters Name=instance-state-name,Values=running \
  --query 'Reservations[*].Instances[*].[InstanceId,InstanceType]' \
  --output text --region eu-central-1

# Then check CPU for a specific instance
aws cloudwatch get-metric-statistics \
  --namespace AWS/EC2 \
  --metric-name CPUUtilization \
  --dimensions Name=InstanceId,Value=i-0abc123 \
  --start-time $(date -u -d '14 days ago' '+%Y-%m-%dT%H:%M:%SZ') \
  --end-time   $(date -u '+%Y-%m-%dT%H:%M:%SZ') \
  --period 86400 --statistics Average \
  --query 'sort_by(Datapoints,&Timestamp)[*].[Timestamp,Average]' \
  --output table --region eu-central-1
```

**Actions based on CPU:**
- 0–2% → **Terminate** (nothing is running on it)
- 2–10% → **Stop** and evaluate — do you still need this?
- 10–20% → **Downsize** to a smaller instance type

### 3.4 Orphaned Snapshots

EBS snapshots are kept indefinitely unless you delete them. Set a lifecycle policy:

```bash
# Delete snapshots older than 90 days (yours only)
aws ec2 describe-snapshots --owner-ids self \
  --query 'Snapshots[?StartTime<=`2026-02-27`].[SnapshotId,StartTime,VolumeSize]' \
  --output table --region eu-central-1

# Delete a specific snapshot
aws ec2 delete-snapshot --snapshot-id snap-0abc123 --region eu-central-1
```

Or use **Amazon Data Lifecycle Manager** to automate snapshot retention policies.

---

## 4. Step 3 — Enforce Governance

Without enforcement, cost waste returns within weeks. Governance means making it **impossible** (SCP) or **immediately visible** (Config rules) to launch untagged, oversized, or unaccounted-for resources.

### 4.1 Service Control Policies (SCPs) — Preventative

SCPs operate at the AWS Organizations level and **block API calls before they happen**. They are the strongest form of governance.

**Example: Block EC2 launch without CostCenter tag**

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyEC2WithoutCostCenter",
      "Effect": "Deny",
      "Action": ["ec2:RunInstances", "ec2:CreateVolume", "ec2:AllocateAddress"],
      "Resource": "*",
      "Condition": {
        "Null": {
          "aws:RequestTag/CostCenter": "true"
        }
      }
    }
  ]
}
```

Apply to a dev/sandbox OU:
```bash
aws organizations create-policy \
  --content file://policies/scp_require_costcenter_tag.json \
  --name "RequireCostCenterTag" \
  --type SERVICE_CONTROL_POLICY

aws organizations attach-policy \
  --policy-id p-xxxx \
  --target-id ou-xxxx-xxxxxxxx
```

### 4.2 AWS Config Rules — Detective

Config rules evaluate existing resources against a policy and flag non-compliance. Unlike SCPs, they don't block actions — but they generate findings that feed into dashboards and alerts.

**Deploy the REQUIRED_TAGS managed rule via CLI:**
```bash
aws configservice put-config-rule \
  --config-rule '{
    "ConfigRuleName": "require-costcenter-ec2",
    "Scope": {"ComplianceResourceTypes": ["AWS::EC2::Instance"]},
    "Source": {"Owner": "AWS", "SourceIdentifier": "REQUIRED_TAGS"},
    "InputParameters": "{\"tag1Key\":\"CostCenter\",\"tag2Key\":\"Environment\"}"
  }' \
  --region eu-central-1
```

**Alert on NON_COMPLIANT findings via EventBridge → SNS:**
```bash
aws events put-rule \
  --name "config-noncompliant-alert" \
  --event-pattern '{
    "source": ["aws.config"],
    "detail-type": ["Config Rules Compliance Change"],
    "detail": {"newEvaluationResult": {"complianceType": ["NON_COMPLIANT"]}}
  }' \
  --region eu-central-1
```

### 4.3 AWS Budgets — Financial Guardrails

Set budgets before you deploy, not after you get the bill.

**Create a $50/month budget with 80% alert:**
```bash
aws budgets create-budget \
  --account-id 195275667627 \
  --budget '{
    "BudgetName": "monthly-sandbox",
    "BudgetLimit": {"Amount": "50", "Unit": "USD"},
    "TimeUnit": "MONTHLY",
    "BudgetType": "COST"
  }' \
  --notifications-with-subscribers '[{
    "Notification": {
      "NotificationType": "FORECASTED",
      "ComparisonOperator": "GREATER_THAN",
      "Threshold": 80,
      "ThresholdType": "PERCENTAGE"
    },
    "Subscribers": [{"SubscriptionType":"EMAIL","Address":"you@example.com"}]
  }]'
```

**Best practice — run multiple budgets in parallel:**

| Budget | Scope | Threshold | Why |
|---|---|---|---|
| Monthly total | All services | $50 (100% forecast) | Overall ceiling |
| EC2 only | EC2 | $30 (90% forecast) | Catch runaway compute early |
| Per-team | Filtered by `CostCenter` tag | Team-specific limit | Showback to engineering leads |

---

## 5. Step 4 — Right-Size Your Compute

### 5.1 Use AWS Compute Optimizer

Compute Optimizer analyses 14 days of CloudWatch metrics and recommends cheaper instance types with similar or better performance.

```
AWS Console → Compute Optimizer → EC2 Instances
```

It will suggest, for example: "downgrade m5.xlarge → m5.large — 65% cost reduction, 0% performance risk based on your usage pattern."

### 5.2 Manual Rightsizing Decision Tree

```
Is instance CPU consistently < 5%?
  → Stop it. If nothing breaks in 7 days, terminate it.

Is instance CPU 5–20%?
  → Drop to the next smaller size in the same family.

Is instance type 3+ generations old (e.g., m3, c3, t2)?
  → Migrate to current generation. t2 → t4g saves 20%+ and performs better.

Is the instance x86 (t3, m5, c5)?
  → Evaluate Graviton (t4g, m7g, c7g). Same price, 20% better perf/$.
    Workloads must be architecture-agnostic (most web services, containers, Python/Node/Go apps).
```

### 5.3 Graviton Migration

Graviton (ARM64) processors are AWS-designed chips that deliver better price-performance than x86 for most general-purpose workloads.

| Instance | vCPU | RAM | On-Demand (eu-central-1) | Saving vs t3 |
|---|---|---|---|---|
| t3.small (x86) | 2 | 2 GB | $0.0228/hr | baseline |
| t4g.small (Graviton2) | 2 | 2 GB | $0.0188/hr | **−18%** |
| t4g.small (Spot) | 2 | 2 GB | ~$0.006/hr | **−74%** |

**Migration steps:**
1. Confirm your application is architecture-agnostic (Docker containers, Python, Node.js, Go, Java — all work on ARM64)
2. Update your AMI to an ARM64 image (Amazon Linux 2023 ARM64, Ubuntu ARM64, etc.)
3. Change `instance_type` to `t4g.*` / `m7g.*` / `c7g.*`
4. Test in staging first — run for at least 48 hours under normal load

---

## 6. Step 5 — Use Spot and Savings Plans

### 6.1 Spot Instances

Spot Instances use AWS spare capacity at up to 90% discount. They can be interrupted with a 2-minute notice. They are ideal for:

- Stateless web applications behind a load balancer
- Batch processing jobs
- CI/CD build agents
- Development and testing environments

**Best practices for Spot:**

1. **Use a Mixed Instances Policy** — never run 100% Spot in production. Keep an On-Demand base.
2. **Diversify instance families** — the more families in your pool, the lower your interruption risk.
3. **Use `capacity-optimized-prioritized` strategy** — AWS picks the pool with the most spare capacity.
4. **Choose Graviton Spot** — ARM64 Spot pools often have higher availability than x86 equivalents.

**Example Mixed Instances Policy (Terraform):**
```hcl
mixed_instances_policy {
  launch_template {
    launch_template_specification {
      launch_template_id = aws_launch_template.app.id
      version            = "$Latest"
    }
    override { instance_type = "t4g.small";  weighted_capacity = "1" }
    override { instance_type = "t4g.medium"; weighted_capacity = "2" }
    override { instance_type = "c7g.medium"; weighted_capacity = "2" }
    override { instance_type = "m7g.medium"; weighted_capacity = "2" }
  }

  instances_distribution {
    on_demand_base_capacity                  = 1
    on_demand_percentage_above_base_capacity = 20
    spot_allocation_strategy                 = "capacity-optimized-prioritized"
  }
}
```

**This achieves:**
- 1 guaranteed On-Demand instance (reliability floor)
- ~80% of scale-out capacity as Spot
- Automatic fallback between 4 Graviton instance families if one is interrupted

### 6.2 Savings Plans

Savings Plans offer discounts of 20–66% on compute in exchange for a 1 or 3 year commitment to a minimum spend level ($0.10/hr minimum). Unlike Reserved Instances, they apply automatically across regions, instance families, and OS types.

**When to buy:**
- You have a stable baseline load you can predict (e.g., you always run at least 2 instances)
- You have 3+ months of Cost Explorer data to understand your baseline

**Types:**
- **Compute Savings Plans** — most flexible, applies to EC2, Fargate, Lambda
- **EC2 Instance Savings Plans** — larger discount but locked to a specific instance family

**How to purchase:**
`AWS Cost Management → Savings Plans → Purchase Savings Plans`

Cost Explorer will recommend an optimal commitment amount based on your historical usage.

### 6.3 Reserved Instances (RDS and ElastiCache)

For databases and caches, Reserved Instances are often the right tool (RDS does not support Spot):

```
RDS On-Demand:   $0.192/hr  (db.t3.medium, MySQL, eu-central-1)
RDS 1-yr Reserved: $0.123/hr  → 36% saving
RDS 3-yr Reserved: $0.082/hr  → 57% saving
```

Buy RIs for any database that has been running continuously for 3+ months.

---

## 7. Step 6 — Architect for Cost from Day One

### 7.1 Networking

Data transfer costs are often invisible until you get the bill.

| Rule | Cost saved |
|---|---|
| Keep traffic within the same AZ when possible | Avoids $0.01/GB inter-AZ transfer |
| Use VPC endpoints for S3 and DynamoDB | Avoids NAT Gateway charges ($0.045/GB) |
| Use CloudFront in front of S3 | Shifts egress from $0.09/GB → $0.0085/GB (at volume) |
| Size NAT Gateways correctly | Each NAT GW = $32.40/mo fixed + $0.045/GB processed |

**Check your NAT Gateway usage:**
```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/NatGateway \
  --metric-name BytesOutToDestination \
  --dimensions Name=NatGatewayId,Value=nat-0abc123 \
  --start-time $(date -u -d '7 days ago' '+%Y-%m-%dT%H:%M:%SZ') \
  --end-time   $(date -u '+%Y-%m-%dT%H:%M:%SZ') \
  --period 86400 --statistics Sum \
  --output table --region eu-central-1
```

### 7.2 Storage

| Action | Saving |
|---|---|
| Migrate gp2 → gp3 EBS | 20% cheaper, 3× baseline IOPS for free |
| Enable S3 Intelligent-Tiering | 40–68% on objects not accessed for 30+ days |
| Set S3 lifecycle rules on log buckets | Transition to Glacier after 90 days, delete after 365 |
| Delete unused EBS snapshots | $0.054/GB/mo — adds up fast on snapshot-heavy environments |

**Migrate a gp2 volume to gp3 in place (no downtime):**
```bash
aws ec2 modify-volume \
  --volume-id vol-0abc123 \
  --volume-type gp3 \
  --region eu-central-1
```

### 7.3 Scheduled Scaling for Non-Production

Development, staging, and sandbox environments don't need to run 24/7.

```bash
# Scale ASG to 0 at 8pm UTC on weekdays, back up at 8am
aws autoscaling put-scheduled-update-group-action \
  --auto-scaling-group-name my-dev-asg \
  --scheduled-action-name scale-down-evening \
  --recurrence "0 20 * * MON-FRI" \
  --min-size 0 --max-size 0 --desired-capacity 0 \
  --region eu-central-1

aws autoscaling put-scheduled-update-group-action \
  --auto-scaling-group-name my-dev-asg \
  --scheduled-action-name scale-up-morning \
  --recurrence "0 8 * * MON-FRI" \
  --min-size 1 --max-size 4 --desired-capacity 2 \
  --region eu-central-1
```

**Estimated saving: ~65% of compute hours** (nights 20:00–08:00 + full weekends = ~110 hrs/wk off out of 168 hrs/wk total).

---

## 8. Step 7 — Set Guardrails and Alerts

### 8.1 Cost Anomaly Detection

AWS Cost Anomaly Detection uses ML to detect unusual spend spikes — often before a budget threshold is crossed.

**Set it up:**
```bash
# Create a monitor (watches all services)
aws ce create-anomaly-monitor \
  --anomaly-monitor '{
    "MonitorName": "all-services-monitor",
    "MonitorType": "DIMENSIONAL",
    "MonitorDimension": "SERVICE"
  }'

# Create a subscription to alert when anomaly > $5
aws ce create-anomaly-subscription \
  --anomaly-subscription '{
    "SubscriptionName": "immediate-alert",
    "MonitorArnList": ["arn:aws:ce::ACCOUNT_ID:anomalymonitor/MONITOR_ID"],
    "Subscribers": [{"Address": "arn:aws:sns:eu-central-1:ACCOUNT_ID:my-topic", "Type": "SNS"}],
    "Frequency": "IMMEDIATE",
    "ThresholdExpression": {
      "Dimensions": {
        "Key": "ANOMALY_TOTAL_IMPACT_ABSOLUTE",
        "MatchOptions": ["GREATER_THAN_OR_EQUAL"],
        "Values": ["5"]
      }
    }
  }'
```

### 8.2 Budget Alerts Layering Strategy

Don't rely on a single 100% alert. Layer them:

```
$50 budget:
  ├── Alert 1: 50% actual  ($25) → "heads up" email
  ├── Alert 2: 80% actual  ($40) → "review now" email
  ├── Alert 3: 100% forecasted → "on track to breach" email
  └── Alert 4: 100% actual ($50) → "breached" email + PagerDuty/Slack
```

### 8.3 Prevent Specific Actions with IAM

Restrict expensive instance types in non-production accounts:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyExpensiveInstances",
      "Effect": "Deny",
      "Action": "ec2:RunInstances",
      "Resource": "arn:aws:ec2:*:*:instance/*",
      "Condition": {
        "StringNotLike": {
          "ec2:InstanceType": ["t4g.*", "t3.*", "t3a.*", "m5.*", "c5.*"]
        }
      }
    }
  ]
}
```

---

## 9. Step 8 — Measure and Repeat

Cost optimization is a loop, not a project.

### Monthly cadence

```
Week 1: Run zombie audit → delete waste → update dashboard
Week 2: Review Compute Optimizer recommendations → rightsize 1-2 resources
Week 3: Check tag compliance report → remediate non-compliant resources
Week 4: Review month-to-date spend vs budget → adjust budgets for next month
```

### Quarterly cadence

- Review Savings Plans utilisation — are you getting the discount you paid for?
- Re-evaluate instance type families — new Graviton generations release frequently
- Archive or delete old S3 data — check the lifecycle policies are working
- Review and update your tagging standard

### Metrics to track

| Metric | Target | How to measure |
|---|---|---|
| Unattached EBS volumes | 0 | Weekly audit script |
| Unassociated EIPs | 0 | Weekly audit script |
| Tagging compliance | 100% | Config rule dashboard |
| Spot % of compute fleet | > 60% (stateless) | CloudWatch ASG dashboard |
| Cost per unit of work | Trending down | Custom business metrics + Cost Explorer |
| Budget adherence | < 80% of limit at mid-month | AWS Budgets |

---

## 10. Quick-Win Checklist

Copy this checklist for any new or inherited AWS account:

**Day 1 (1–2 hours)**
- [ ] Enable Cost Explorer
- [ ] Enable Trusted Advisor checks
- [ ] Set a $50/month budget with email alerts at 80% and 100%
- [ ] Enable Cost Anomaly Detection

**Week 1 (2–4 hours)**
- [ ] Run `audit_zombie_assets.sh` — record total waste found
- [ ] Delete all unattached EBS volumes (after confirming no snapshots needed)
- [ ] Release all unassociated Elastic IPs
- [ ] Stop all instances with < 5% CPU for 14 days
- [ ] Tag all untagged running resources

**Month 1 (ongoing)**
- [ ] Migrate at least one workload from gp2 → gp3 EBS
- [ ] Enable S3 lifecycle rules on all log/backup buckets
- [ ] Migrate at least one On-Demand ASG to Mixed Instances (On-Demand base + Spot)
- [ ] Evaluate Graviton migration for top-3 EC2 spend instances
- [ ] Set up AWS Config REQUIRED_TAGS rules

**Quarter 1**
- [ ] Purchase Compute Savings Plans for stable baseline workloads
- [ ] Purchase RDS Reserved Instances for any database running > 3 months
- [ ] Review and present cost reduction report to stakeholders

---

## 11. Common Mistakes to Avoid

| Mistake | Consequence | Fix |
|---|---|---|
| Not tagging resources at launch | Impossible to attribute cost later | Enforce tags via SCP and provider `default_tags` |
| Using a single large instance instead of Auto Scaling | Paying for peak capacity 24/7 | Always use ASGs for web workloads |
| Running dev/staging 24/7 | 2–3× necessary compute cost | Add scheduled scaling (nights + weekends) |
| Forgetting about EBS and EIP when terminating instances | Ongoing waste after instance is gone | Run garbage collector script after every termination |
| 100% Spot instances in production | Outage risk on interruption surge | Always keep an On-Demand base capacity |
| Single budget alert at 100% | Bill already arrived when you find out | Layer alerts: 50%, 80%, 100% forecast, 100% actual |
| Buying Reserved Instances before understanding usage | Locked in to wrong instance family | Wait 3 months, use Cost Explorer RI recommendations |
| Never reviewing Savings Plans utilisation | Paying for savings you're not using | Check utilisation monthly in Cost Explorer |
| Skipping Cost Anomaly Detection | No warning until budget alert fires | Set up anomaly detection — it's free |
| Treating cost optimization as a one-off project | Waste returns within weeks | Make it a recurring engineering ritual |

---

## Summary

The path from a wasteful inherited account to a cost-efficient, well-governed environment follows a clear sequence:

```
1. See it     → Cost Explorer + tags + dashboards
2. Clean it   → Delete zombie assets (EBS, EIP, idle EC2)
3. Guard it   → SCPs + Config rules + budget alerts
4. Optimize   → Graviton + Spot + Savings Plans + scheduled scaling
5. Sustain    → Automated scans + monthly cadence + team accountability
```

The infrastructure built in this project implements all five stages. The scripts, Terraform modules, and policies are reusable — adapt them to any team or account by changing the variables.

---

*For questions or contributions, raise an issue in the project repository.*
