# The Cost Detective — FinOps Audit

**Account inherited:** previous team (reckless spend)  
**Audit date:** 2026-05-27  
**FinOps engineer:** Abraham Gyamfi  
**Budget constraint:** $50 / month hard ceiling  
**Region:** eu-central-1 (Frankfurt)  
**Account ID:** 195275667627  

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Phase 1 — Analysis & Zombie Asset Cleanup](#phase-1--analysis--zombie-asset-cleanup)
3. [Phase 2 — Governance (Budgets + Tagging Policy)](#phase-2--governance-budgets--tagging-policy)
4. [Phase 2.5 — Cost Anomaly Detection](#phase-25--cost-anomaly-detection)
5. [Phase 3 — Cost-Aware Architecture (Graviton + Spot ASG)](#phase-3--cost-aware-architecture-graviton--spot-asg)
6. [Phase 4 — Observability (CloudWatch Dashboard)](#phase-4--observability-cloudwatch-dashboard)
7. [Terraform Module Reference](#terraform-module-reference)
8. [Runbook — Day-to-Day Operations](#runbook--day-to-day-operations)
9. [Cost Optimization Cheat Sheet](#cost-optimization-cheat-sheet)

---

## Architecture Overview

```
AWS Account (195275667627) — eu-central-1
├── module: zombie_assets        ← sandbox simulation of inherited waste
├── module: budgets              ← SNS alerts + Cost Anomaly Detection
├── module: tagging_governance   ← AWS Config rules (4 tags, 3 resource types) + EventBridge alerts
├── module: compute              ← ALB → Graviton ASG (1 On-Demand base + 80% Spot scale-out)
└── aws_cloudwatch_dashboard     ← FinOps visibility: Spot %, CPU, ALB metrics

scripts/
├── audit_zombie_assets.sh       ← READ-ONLY: detect waste, export JSON report
└── garbage_collector.sh         ← MUTATING: delete/stop zombie resources

policies/
├── scp_require_costcenter_tag.json   ← SCP: blocks RunInstances without CostCenter
└── tagging_policy.json               ← Organisation tagging standard document
```

---

## Phase 1 — Analysis & Zombie Asset Cleanup

### 1.1 What Are Zombie Assets?

| Asset type | Problem | Typical cost |
|---|---|---|
| Unattached EBS volume | Created for an instance that was terminated; volume left behind | $0.08–$0.143/GB/mo |
| Unassociated Elastic IP | IP reserved but not linked to a running instance | $3.60/EIP/mo |
| Idle EC2 instance | Running at < 5% avg CPU — doing nothing, billed at full rate | $15–$140/mo |
| Old EBS snapshot | Point-in-time copy never cleaned up after DR window closed | $0.05/GB/mo |

### 1.2 Simulated "Wasteful" Resources (Sandbox)

The `zombie_assets` Terraform module deployed the following intentionally wasteful resources to eu-central-1:

```
Resource                     ID                        Monthly cost
─────────────────────────────────────────────────────────────────────
aws_ebs_volume.gp3           vol-011feb2b5c4855e95     ~$4.76/mo  (50GB gp3)
aws_ebs_volume.st1           vol-01de5ba9660fad6b8     ~$6.25/mo  (125GB st1)
aws_ebs_volume.io2           vol-0368484a5b0bf4eb5     ~$14.30/mo (100GB io2, 3000 IOPS)
aws_eip.one                  eipalloc-09110719e3f5359c4 ~$3.60/mo
aws_eip.two                  eipalloc-0eb09eb3fe79ec319 ~$3.60/mo
aws_instance.idle            i-0142f694ca127b8af        ~$154.76/mo (m5.xlarge, 0% CPU)
```

**Total simulated waste: ~$187.27/month ($2,247.24/year)**

> The idle instance is intentionally missing the `CostCenter` tag — this triggers the AWS Config NON_COMPLIANT finding and simulates a governance gap.

### 1.3 Running the Audit (Read-Only)

```bash
cd /path/to/FinOps

# Detect all zombie assets — no changes made
./scripts/audit_zombie_assets.sh --region eu-central-1

# Save output to a dated file
./scripts/audit_zombie_assets.sh --region eu-central-1 \
  --output "audit_$(date +%Y%m%d).json"

# With a named AWS profile
./scripts/audit_zombie_assets.sh --region eu-central-1 --profile sandbox-ro
```

**Audit checks performed:**

1. EBS volumes in `available` state (never or no longer attached)
2. Elastic IPs with no `AssociationId` (not linked to any instance)
3. EC2 instances with 14-day average CPU < 5% (CloudWatch metrics)
4. EC2/EBS resources missing the mandatory `CostCenter` tag
5. EBS snapshots older than 90 days

### 1.4 Garbage Collection

```bash
# Step 1 — Preview what would be deleted (always start here)
./scripts/garbage_collector.sh --region eu-central-1

# Step 2 — Delete EBS and EIPs only (safer first pass)
./scripts/garbage_collector.sh --region eu-central-1 --delete --skip-ec2

# Step 3 — Full cleanup including stopping idle instances
./scripts/garbage_collector.sh --region eu-central-1 --delete

# Skip EIPs if another team manages networking
./scripts/garbage_collector.sh --region eu-central-1 --delete --skip-eips
```

The script outputs a `gc_report.json` with every action taken and cost saved.

**Expected output after running against the sandbox:**
```
── UNATTACHED EBS VOLUMES ──
  ✗ vol-011feb2b5c4855e95   gp3     50  eu-central-1a  $4.76/mo
  ✗ vol-01de5ba9660fad6b8   st1    125  eu-central-1a  $6.25/mo
  ✗ vol-0368484a5b0bf4eb5   io2    100  eu-central-1a  $14.30/mo
  EBS waste: $25.31/mo

── UNASSOCIATED ELASTIC IPs ──
  ✗ eipalloc-09110719e3f5359c4   x.x.x.x   $3.60/mo
  ✗ eipalloc-0eb09eb3fe79ec319   x.x.x.x   $3.60/mo
  EIP waste: $7.20/mo

── IDLE EC2 INSTANCES ──
  ✗ i-0142f694ca127b8af   m5.xlarge   avg 0.0%   $154.76/mo
  EC2 waste: $154.76/mo

── COST WASTE SUMMARY ──
  Unattached EBS volumes       $25.31/mo
  Unassociated Elastic IPs     $7.20/mo
  Idle EC2 instances           $154.76/mo
  ─────────────────────────────────────────
  TOTAL                        $187.27/mo  (~$2,247.24/yr)
```

### 1.5 Manual Checks via AWS Console

**Cost Explorer path:**
`AWS Console → Cost Management → Cost Explorer → Explore costs → Filter by Service / Usage Type`

Look for:
- `EBS:VolumeUsage` lines with no EC2 tag or in `available` state
- `ElasticIP:IdleAddress` charges
- `BoxUsage:m5.xlarge` or similar unexplained large-instance charges

**Trusted Advisor checks** (Business/Enterprise support required):
- Low Utilisation Amazon EC2 Instances
- Unassociated Elastic IP Addresses
- Underutilised Amazon EBS Volumes

**AWS Config compliance view:**
`AWS Console → Config → Rules → require-costcenter-ec2 → Resources in scope`
The idle instance `i-0142f694ca127b8af` will appear as NON_COMPLIANT (missing CostCenter tag by design).

---

## Phase 2 — Governance (Budgets + Tagging Policy)

### 2.1 AWS Budgets

Two budgets deployed via the `budgets` module (suffix: `1bebdb3f`):

| Budget | Scope | Limit | Alerts |
|---|---|---|---|
| `finops-monthly-sandbox-1bebdb3f` | All services | $50/mo | 80% actual, 100% forecasted, 100% actual |
| `finops-ec2-sandbox-1bebdb3f` | EC2 only | $30/mo (60% of $50) | 90% forecasted |

All alerts publish to SNS topic `finops-budget-alerts-1bebdb3f` → email to `budget_alert_email`.

**Key design decisions:**

- **Forecasted alert** fires days before breach — gives time to react before the bill lands
- **EC2-scoped budget** catches runaway compute independently of e.g. S3 data transfer spikes
- SNS topic uses KMS encryption (`alias/aws/sns`) — alert payloads are encrypted at rest
- `aws:SourceAccount` condition on the SNS policy prevents cross-account abuse

### 2.2 Tagging Policy

**Mandatory tags** (enforced via SCP + Config Rule):

| Tag key | Purpose | Example value |
|---|---|---|
| `CostCenter` | Billing allocation | `eng-platform` |
| `Environment` | Deployment tier | `sandbox` / `prod` |
| `ManagedBy` | Provisioning tool | `Terraform` |
| `Project` | Business initiative | `FinOps-CostDetective` |

### 2.3 Preventative Control — Service Control Policy (SCP)

File: `policies/scp_require_costcenter_tag.json`

The SCP applies a **Deny** effect on:
- `ec2:RunInstances` — blocks launching any instance without `CostCenter`
- `ec2:CreateVolume` — blocks creating any EBS volume without `CostCenter`
- `ec2:AllocateAddress` — blocks reserving Elastic IPs without `CostCenter`
- `ec2:DeleteTags` — prevents removing the `CostCenter` tag after the fact

**To attach the SCP in AWS Organizations:**
```bash
# 1. Create the SCP
aws organizations create-policy \
  --content file://policies/scp_require_costcenter_tag.json \
  --name "RequireCostCenterTag" \
  --type SERVICE_CONTROL_POLICY \
  --description "Block EC2/EBS/EIP creation without CostCenter tag"

# 2. Attach to target OU (replace ou-xxxx-xxxxxxxx)
aws organizations attach-policy \
  --policy-id p-xxxxxxxxxxxx \
  --target-id ou-xxxx-xxxxxxxx
```

### 2.4 Detective Control — AWS Config Rules

Three `REQUIRED_TAGS` managed rules deployed (suffix: `1bebdb3f`):

| Rule name | Resource type | Tags required |
|---|---|---|
| `require-costcenter-ec2` | `AWS::EC2::Instance` | `CostCenter`, `Environment`, `ManagedBy`, `Project` |
| `require-costcenter-ebs` | `AWS::EC2::Volume` | `CostCenter`, `Environment`, `ManagedBy`, `Project` |
| `require-costcenter-eip` | `AWS::EC2::EIP` | `CostCenter` |

Config evaluates resources:
- On configuration change (near real-time)
- On a periodic 24-hour schedule

Non-compliant findings trigger: EventBridge Rule → SNS topic `finops-compliance-1bebdb3f` → email alert.

**To view compliance in the console:**
`AWS Config → Rules → require-costcenter-ec2 → Resources in scope`

**To query compliance via CLI:**
```bash
aws configservice describe-compliance-by-config-rule \
  --config-rule-names require-costcenter-ec2 require-costcenter-ebs require-costcenter-eip \
  --compliance-types NON_COMPLIANT \
  --region eu-central-1
```

---

## Phase 2.5 — Cost Anomaly Detection

### Why budgets alone are not enough

AWS Budgets alert when cumulative spend crosses a threshold. They cannot detect a sudden spike within the current billing period until enough spend has accumulated. Cost Anomaly Detection uses ML to baseline your per-service spend and fires as soon as it sees an unexpected deviation — often days before a budget alert would trigger.

### What was deployed

| Resource | Details |
|---|---|
| `aws_ce_anomaly_monitor` | `DIMENSIONAL / SERVICE` — watches every AWS service independently |
| `aws_ce_anomaly_subscription` | `IMMEDIATE` frequency — alerts as soon as anomaly is confirmed |
| SNS target | Reuses `finops-budget-alerts-1bebdb3f` — same email inbox as budget alerts |

**Threshold:** fires when anomaly's total dollar impact reaches **$5** (absolute). Appropriate for a $50/month ceiling — any $5 deviation is 10% of budget.

**Monitor ARN:** `arn:aws:ce::195275667627:anomalymonitor/47188c2c-f37d-4a56-b191-e971dbe80ca9`

### Console path

`AWS Cost Management → Cost Anomaly Detection → Monitors → finops-service-monitor-1bebdb3f`

---

## Phase 3 — Cost-Aware Architecture (Graviton + Spot ASG)

### 3.1 Design Goals

| Goal | Implementation |
|---|---|
| Eliminate single-point-of-failure | Multi-AZ ALB + ASG across eu-central-1a and eu-central-1b |
| Reduce compute cost by 70–80% | Graviton ARM64 + 80% Spot for scale-out capacity |
| Maintain availability during Spot interruptions | `capacity-optimized-prioritized` strategy + 4-family Graviton pool |
| Auto-scale on real demand | CPU target-tracking policy at 60% |
| Enforce governance | IMDSv2, encrypted EBS, SSM agent, CostCenter tag propagation |
| Modern supported OS | Amazon Linux 2023 ARM64 (`ami-0d3afa848fc8b043e`) — replaces EOL Amazon Linux 2 |

### 3.2 Live Resources

| Resource | ID / Name |
|---|---|
| ALB | `finops-alb-1bebdb3f` |
| ALB DNS | `finops-alb-1bebdb3f-534148037.eu-central-1.elb.amazonaws.com` |
| ASG | `finops-asg-1bebdb3f` |
| Launch Template | `finops-lt-*` |
| CloudWatch Dashboard | `FinOps-CostDetective-1bebdb3f` |
| Config S3 Bucket | `finops-config-195275667627-1bebdb3f` |

### 3.3 Graviton Instance Pool

All four overrides use ARM64 Graviton processors — ~20% cheaper than equivalent x86 On-Demand, and up to 90% savings over x86 On-Demand when running as Spot:

```
Override (Launch Template):
  t4g.small   weight=1  — Graviton2, cheapest general-purpose
  t4g.medium  weight=2  — Graviton2, 2× RAM
  c7g.medium  weight=2  — Graviton3, compute-optimised
  m7g.medium  weight=2  — Graviton3, memory-optimised
```

### 3.4 Mixed Instances Policy

```
Instance distribution (eu-central-1 pricing):
  on_demand_base_capacity                  = 1
  on_demand_percentage_above_base_capacity = 20
  spot_allocation_strategy = "capacity-optimized-prioritized"

At desired=2:
  Instance 0 → On-Demand t4g.small  (~$0.0188/hr → $13.72/mo)
  Instance 1 → Spot      (best Graviton pool, avg ~$0.006/hr → ~$4.38/mo)

At desired=6 (scale-out):
  1 × On-Demand  +  5 × Spot  →  ~80% savings vs all On-Demand
```

### 3.5 Spot Interruption Handling

- `instance_initiated_shutdown_behavior = terminate` — instance drains cleanly on the 2-min notice
- ALB health check deregisters unhealthy targets within 60 seconds
- `min_healthy_percentage = 50` — rolling updates never take more than half the fleet offline
- Four Graviton families in the pool → higher combined Spot capacity → fewer interruptions

### 3.6 Scheduled Scaling (Sandbox Cost Saving ~65%)

When `enable_scheduled_scaling = true`:

| Schedule | Cron (UTC) | Effect |
|---|---|---|
| `scale_down_evening` | `0 20 * * MON-FRI` | Collapse to min=1, desired=1 |
| `scale_up_morning` | `0 8 * * MON-FRI` | Restore normal sizing |
| `scale_down_weekend` | `0 0 * * SAT` | Collapse to min=1, desired=1 |
| `scale_up_monday` | `0 7 * * MON` | Restore 1 hr before business hours |

```bash
terraform apply -var="budget_alert_email=you@example.com" \
                -var="enable_scheduled_scaling=true"
```

### 3.7 Verify the Deployment

```bash
# Test ALB is reachable and serving traffic
curl http://finops-alb-1bebdb3f-534148037.eu-central-1.elb.amazonaws.com

# Check ASG instance count
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names finops-asg-1bebdb3f \
  --query 'AutoScalingGroups[0].{Desired:DesiredCapacity,Min:MinSize,Max:MaxSize,Instances:Instances[*].InstanceId}' \
  --region eu-central-1

# See Spot vs On-Demand split
aws autoscaling describe-auto-scaling-instances \
  --region eu-central-1 \
  --query 'AutoScalingInstances[?AutoScalingGroupName==`finops-asg-1bebdb3f`].[InstanceId,InstanceType,LifecycleState,MarketOption]' \
  --output table
```

---

## Phase 4 — Observability (CloudWatch Dashboard)

### What was deployed

Dashboard `FinOps-CostDetective-1bebdb3f` — five widgets in a 24-column grid:

| Widget | Metrics | Purpose |
|---|---|---|
| ASG Spot vs On-Demand (stacked area) | `GroupDesiredCapacity`, `GroupInServiceInstances` | Visualise Spot % in real time |
| CPU Utilization vs 60% Target | `AWS/EC2 CPUUtilization` | See when scale-out triggers |
| ALB Request Count | `AWS/ApplicationELB RequestCount` | Traffic baseline |
| ALB 5XX Errors | `AWS/ApplicationELB HTTPCode_ELB_5XX_Count` | Spot interruption blast radius |
| Desired vs In-Service (full width) | `AWS/AutoScaling` | Capacity health at a glance |

**Console path:**
`CloudWatch → Dashboards → FinOps-CostDetective-1bebdb3f`

### S3 Config Bucket Lifecycle

The `finops-config-195275667627-1bebdb3f` bucket has a lifecycle rule that:
- Expires Config snapshot objects after **90 days**
- Purges non-current versions after **30 days**
- Aborts incomplete multipart uploads after **7 days**

Expected ongoing S3 cost: < $0.01/month.

---

## Terraform Module Reference

```
terraform/
├── main.tf                          ← provider, locals, module wiring, CloudWatch dashboard
├── variables.tf                     ← all input variables (region default: eu-central-1)
├── outputs.tf                       ← root outputs including dashboard_name, anomaly_monitor_arn
├── terraform.tfvars                 ← budget_alert_email (gitignored in production)
├── terraform.tfvars.example         ← copy → terraform.tfvars and customise
└── modules/
    ├── zombie_assets/               ← sandbox waste simulation (3 EBS, 2 EIP, 1 idle EC2)
    ├── budgets/                     ← SNS + 2× AWS Budgets + Cost Anomaly Detection
    ├── tagging_governance/          ← AWS Config + EventBridge + S3 lifecycle
    └── compute/                     ← VPC + ALB + Graviton Mixed-Instances ASG
```

### Key Outputs (current deployment)

| Output | Value |
|---|---|
| `region` | `eu-central-1` |
| `account_id` | `195275667627` |
| `alb_dns_name` | `finops-alb-1bebdb3f-534148037.eu-central-1.elb.amazonaws.com` |
| `asg_name` | `finops-asg-1bebdb3f` |
| `dashboard_name` | `FinOps-CostDetective-1bebdb3f` |
| `config_bucket` | `finops-config-195275667627-1bebdb3f` |
| `idle_instance_id` | `i-0142f694ca127b8af` |
| `zombie_ebs_volumes` | `vol-011feb2b5c4855e95`, `vol-01de5ba9660fad6b8`, `vol-0368484a5b0bf4eb5` |
| `zombie_eips` | `eipalloc-09110719e3f5359c4`, `eipalloc-0eb09eb3fe79ec319` |
| `anomaly_monitor_arn` | `arn:aws:ce::195275667627:anomalymonitor/47188c2c-...` |

---

## Runbook — Day-to-Day Operations

### Weekly zombie scan

```bash
./scripts/audit_zombie_assets.sh --region eu-central-1 \
  --output "audit_$(date +%Y%m%d).json"
```

### Monthly cleanup pass

```bash
# Always dry-run first
./scripts/garbage_collector.sh --region eu-central-1

# Review gc_report.json, then delete EBS/EIPs first
./scripts/garbage_collector.sh --region eu-central-1 --delete --skip-ec2

# Finally stop idle instances (after manual confirmation)
./scripts/garbage_collector.sh --region eu-central-1 --delete
```

### Check Config compliance

```bash
aws configservice describe-compliance-by-config-rule \
  --config-rule-names require-costcenter-ec2 require-costcenter-ebs require-costcenter-eip \
  --compliance-types NON_COMPLIANT \
  --region eu-central-1
```

### Tag a non-compliant resource

```bash
aws ec2 create-tags \
  --resources i-0142f694ca127b8af \
  --tags Key=CostCenter,Value=finops-audit \
         Key=Environment,Value=sandbox \
         Key=ManagedBy,Value=Terraform \
         Key=Project,Value=FinOps-CostDetective \
  --region eu-central-1
```

### Destroy zombie sandbox after demo

```bash
cd terraform
# Remove only zombie resources, keep governance + ASG
terraform destroy -target=module.zombie_assets

# Or tear everything down
terraform destroy
```

---

## Cost Optimization Cheat Sheet

| Lever | Typical saving | Effort | Status in this project |
|---|---|---|---|
| Delete unattached EBS volumes | 100% of volume cost | Low — run the script | Script provided |
| Release idle EIPs | $3.60/EIP/mo | Low — run the script | Script provided |
| Stop/rightsize idle instances | 50–100% of instance cost | Medium — validate workload first | Script provided |
| Switch On-Demand → Graviton Spot (stateless) | 70–80% | Medium — Mixed Instances Policy | **Implemented** |
| AL2023 migration (drop EOL Amazon Linux 2) | Security + support | Low — update AMI | **Implemented** |
| Scheduled scaling (nights + weekends) | ~65% of compute hours | Low — `enable_scheduled_scaling=true` | **Implemented** |
| Cost Anomaly Detection | Early warning, not $ saving | Low — Terraform resource | **Implemented** |
| S3 lifecycle on Config bucket | Negligible — principle | Low — lifecycle rule | **Implemented** |
| Enforce tagging on all resource types | Visibility + showback | Medium — Config + SCP | **Implemented** |
| Switch On-Demand → Savings Plans (steady-state) | 20–66% | Low — purchase in Cost Explorer | Recommended next |
| gp2 → gp3 EBS migration | ~20% cheaper, better perf | Low — `aws ec2 modify-volume` | Recommended next |
| Enable S3 Intelligent-Tiering | 40–60% on infrequent objects | Low — bucket lifecycle rule | Recommended next |
| Compute Optimizer rightsizing | Variable | Low — review recommendations | Recommended next |

---

*Document maintained by the FinOps team. Update after every quarterly audit.*
