# FinOps — Cost Detective

A production-grade AWS FinOps toolkit for auditing, governing, and optimising cloud spend. Built around a $50/month hard ceiling on a sandbox account inherited with significant waste.

## Overview

| Phase | What it does |
|---|---|
| **1 — Zombie Audit** | Detects and removes unattached EBS volumes, idle EIPs, and idle EC2 instances |
| **2 — Governance** | AWS Budgets, Cost Anomaly Detection, Config rules, and SCP tagging enforcement |
| **3 — Cost-Aware Compute** | Graviton + Spot Mixed Instances ASG behind an ALB — 70–80% compute savings |
| **4 — Observability** | CloudWatch dashboard tracking Spot %, CPU, ALB traffic, and 5XX errors |

## Project Structure

```
FinOps/
├── docs/
│   ├── COST_DETECTIVE_AUDIT.md       # Full audit walkthrough and runbook
│   └── COST_OPTIMIZATION_GUIDE.md   # End-to-end AWS cost optimisation guide
├── policies/
│   ├── scp_require_costcenter_tag.json  # SCP: blocks EC2/EBS/EIP without CostCenter tag
│   └── tagging_policy.json              # Organisation tagging standard
├── scripts/
│   ├── audit_zombie_assets.sh        # Read-only: detect waste, export JSON report
│   └── garbage_collector.sh          # Mutating: delete/stop zombie resources
└── terraform/
    ├── main.tf
    ├── variables.tf
    ├── outputs.tf
    ├── terraform.tfvars.example      # Copy to terraform.tfvars and fill in values
    └── modules/
        ├── zombie_assets/            # Sandbox waste simulation
        ├── budgets/                  # SNS + AWS Budgets + Cost Anomaly Detection
        ├── tagging_governance/       # AWS Config + EventBridge + S3 lifecycle
        └── compute/                  # VPC + ALB + Graviton Mixed-Instances ASG
```

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) v2 configured with appropriate credentials
- An AWS account with permissions for EC2, IAM, Config, Budgets, Cost Explorer, and CloudWatch

## Quick Start

```bash
# 1. Clone the repo
git clone https://github.com/AbrahamGyamfi/FinOps.git
cd FinOps

# 2. Configure Terraform variables
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit terraform.tfvars — set budget_alert_email at minimum

# 3. Deploy
cd terraform
terraform init
terraform plan
terraform apply
```

## Scripts

### Audit (read-only)

```bash
# Detect zombie assets — no changes made
./scripts/audit_zombie_assets.sh --region eu-central-1

# Save to a dated file
./scripts/audit_zombie_assets.sh --region eu-central-1 --output "audit_$(date +%Y%m%d).json"
```

### Garbage Collection

```bash
# Dry run — preview what would be deleted
./scripts/garbage_collector.sh --region eu-central-1

# Delete EBS and EIPs only (safer first pass)
./scripts/garbage_collector.sh --region eu-central-1 --delete --skip-ec2

# Full cleanup including stopping idle instances
./scripts/garbage_collector.sh --region eu-central-1 --delete
```

## Governance

### Tagging Standard

All resources must carry these four tags:

| Tag | Example |
|---|---|
| `CostCenter` | `eng-platform` |
| `Environment` | `sandbox` / `prod` |
| `ManagedBy` | `Terraform` |
| `Project` | `FinOps-CostDetective` |

### SCP Enforcement

`policies/scp_require_costcenter_tag.json` blocks `ec2:RunInstances`, `ec2:CreateVolume`, and `ec2:AllocateAddress` without a `CostCenter` tag. Attach it to your target OU:

```bash
aws organizations create-policy \
  --content file://policies/scp_require_costcenter_tag.json \
  --name "RequireCostCenterTag" \
  --type SERVICE_CONTROL_POLICY

aws organizations attach-policy \
  --policy-id p-xxxxxxxxxxxx \
  --target-id ou-xxxx-xxxxxxxx
```

## Cost Results (Sandbox)

| Item | Before | After |
|---|---|---|
| Zombie assets (EBS + EIP + idle EC2) | $187.27/mo | $0 |
| Compute (On-Demand → Graviton Spot) | ~$154/mo | ~$18/mo |
| Total estimated monthly spend | > $340/mo | < $50/mo |

## Documentation

- [Cost Detective Audit](docs/COST_DETECTIVE_AUDIT.md) — full phase-by-phase walkthrough, resource IDs, and day-to-day runbook
- [Cost Optimisation Guide](docs/COST_OPTIMIZATION_GUIDE.md) — reusable end-to-end guide for any AWS account

## Security

- Terraform state and `terraform.tfvars` are excluded from version control via `.gitignore`
- SNS topics use KMS encryption (`alias/aws/sns`)
- All EC2 instances enforce IMDSv2 and encrypted EBS volumes
- To report a security issue, please contact the repository owner directly rather than opening a public issue

## License

MIT
