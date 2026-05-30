#!/usr/bin/env bash
# ============================================================
# FinOps Garbage Collector
# Removes zombie AWS assets: unattached EBS volumes,
# unassociated Elastic IPs, idle EC2 instances (stops them).
#
# Usage:
#   ./garbage_collector.sh --region us-east-1            # dry-run (safe)
#   ./garbage_collector.sh --region us-east-1 --delete   # live cleanup
#   ./garbage_collector.sh --delete --skip-ec2           # skip idle EC2 check
# ============================================================
set -euo pipefail

REGION="eu-central-1"
PROFILE_FLAG=""
DELETE=false
SKIP_EIPS=false
SKIP_EC2=false
CPU_THRESHOLD=5
REPORT="gc_report.json"

while [[ $# -gt 0 ]]; do
  case $1 in
    --region)        REGION="$2";            shift 2 ;;
    --profile)       PROFILE_FLAG="--profile $2"; shift 2 ;;
    --delete)        DELETE=true;            shift ;;
    --skip-eips)     SKIP_EIPS=true;        shift ;;
    --skip-ec2)      SKIP_EC2=true;         shift ;;
    --cpu-threshold) CPU_THRESHOLD="$2";    shift 2 ;;
    --report)        REPORT="$2";           shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

AWS="aws $PROFILE_FLAG --region $REGION --output text"
RED='\033[91m'; GRN='\033[92m'; YEL='\033[93m'
CYA='\033[96m'; BOLD='\033[1m'; RESET='\033[0m'

section() { echo -e "\n${BOLD}${CYA}── $1 ──${RESET}"; }

echo -e "\n${BOLD}FinOps Garbage Collector${RESET}"
echo -e "  Region : $REGION"
if $DELETE; then
  echo -e "  Mode   : ${RED}${BOLD}DELETE${RESET} — resources WILL be removed"
else
  echo -e "  Mode   : ${YEL}DRY-RUN${RESET} — no changes will be made (pass --delete to act)"
fi

REPORT_DATA='{"unattached_volumes":[],"unassociated_eips":[],"idle_instances":[]}'
VOL_WASTE=0; EIP_WASTE=0; EC2_WASTE=0

# ── 1. Unattached EBS Volumes ─────────────────────────────────
section "UNATTACHED EBS VOLUMES"
VOLS=$($AWS ec2 describe-volumes \
  --filters Name=status,Values=available \
  --query 'Volumes[*].[VolumeId,VolumeType,Size,AvailabilityZone]' 2>/dev/null || true)

if [[ -z "$VOLS" ]]; then
  echo -e "  ${GRN}✓  None found${RESET}"
else
  printf "  %-25s %-6s %5s  %-20s\n" "VolumeId" "Type" "GB" "AZ"
  printf "  %s\n" "$(printf '─%.0s' {1..60})"
  while IFS=$'\t' read -r vid vtype size az; do
    [[ -z "$vid" ]] && continue
    # Estimate cost (gp3=0.08, io2=0.125, st1=0.045 per GB/mo)
    case $vtype in
      gp3) rate="0.08" ;; gp2) rate="0.10" ;;
      io1|io2) rate="0.125" ;; st1) rate="0.045" ;; *) rate="0.08" ;;
    esac
    COST=$(awk -v s="$size" -v r="$rate" 'BEGIN{printf "%.2f", s*r}')
    VOL_WASTE=$(awk -v a="$VOL_WASTE" -v b="$COST" 'BEGIN{printf "%.2f", a+b}')

    REPORT_DATA=$(echo "$REPORT_DATA" | jq \
      --arg id "$vid" --arg t "$vtype" --argjson s "$size" --arg az "$az" --arg c "$COST" \
      '.unattached_volumes += [{"id":$id,"type":$t,"size_gb":$s,"az":$az,"monthly_cost_usd":$c}]')

    echo -e "  ${RED}✗${RESET} $(printf '%-25s %-6s %5s  %-20s  $%s/mo' "$vid" "$vtype" "$size" "$az" "$COST")"
    if $DELETE; then
      aws $PROFILE_FLAG --region "$REGION" ec2 delete-volume --volume-id "$vid" && \
        echo -e "      ${GRN}→ Deleted${RESET}" || \
        echo -e "      ${RED}→ Failed to delete${RESET}"
    fi
  done <<< "$VOLS"
  echo -e "\n  EBS waste: \$${VOL_WASTE}/mo"
fi

# ── 2. Unassociated Elastic IPs ───────────────────────────────
if ! $SKIP_EIPS; then
  section "UNASSOCIATED ELASTIC IPs"
  EIPS=$($AWS ec2 describe-addresses \
    --query 'Addresses[?AssociationId==null].[AllocationId,PublicIp]' 2>/dev/null || true)

  if [[ -z "$EIPS" ]]; then
    echo -e "  ${GRN}✓  None found${RESET}"
  else
    while IFS=$'\t' read -r alloc ip; do
      [[ -z "$alloc" ]] && continue
      EIP_WASTE=$(awk -v a="$EIP_WASTE" 'BEGIN{printf "%.2f", a+3.60}')
      REPORT_DATA=$(echo "$REPORT_DATA" | jq \
        --arg a "$alloc" --arg ip "$ip" \
        '.unassociated_eips += [{"allocation_id":$a,"public_ip":$ip,"monthly_cost_usd":"3.60"}]')
      echo -e "  ${RED}✗${RESET} $(printf '%-32s %-20s  $3.60/mo' "$alloc" "$ip")"
      if $DELETE; then
        aws $PROFILE_FLAG --region "$REGION" ec2 release-address --allocation-id "$alloc" && \
          echo -e "      ${GRN}→ Released${RESET}" || \
          echo -e "      ${RED}→ Failed to release${RESET}"
      fi
    done <<< "$EIPS"
    echo -e "\n  EIP waste: \$${EIP_WASTE}/mo"
  fi
fi

# ── 3. Idle EC2 Instances ────────────────────────────────────
if ! $SKIP_EC2; then
  section "IDLE EC2 INSTANCES  (avg CPU < ${CPU_THRESHOLD}% / 14 days)"
  INSTANCES=$($AWS ec2 describe-instances \
    --filters Name=instance-state-name,Values=running \
    --query 'Reservations[*].Instances[*].[InstanceId,InstanceType]' 2>/dev/null || true)

  IDLE_FOUND=0; CHECKED=0
  END_TIME=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  START_TIME=$(date -u -d '14 days ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
               date -u -v-14d '+%Y-%m-%dT%H:%M:%SZ')

  while IFS=$'\t' read -r iid itype; do
    [[ -z "$iid" ]] && continue
    ((CHECKED++)) || true
    AVG_CPU=$($AWS cloudwatch get-metric-statistics \
      --namespace AWS/EC2 --metric-name CPUUtilization \
      --dimensions Name=InstanceId,Value="$iid" \
      --start-time "$START_TIME" --end-time "$END_TIME" \
      --period 86400 --statistics Average \
      --query 'average(Datapoints[*].Average)' 2>/dev/null || echo "0")
    AVG_CPU=${AVG_CPU:-0}

    IS_IDLE=$(awk -v cpu="$AVG_CPU" -v thr="$CPU_THRESHOLD" 'BEGIN{print (cpu+0 < thr+0) ? "yes" : "no"}')
    if [[ "$IS_IDLE" == "yes" ]]; then
      # Rough hourly rate lookup
      case $itype in
        t3.micro) hourly="0.0104" ;; t3.small) hourly="0.0208" ;;
        t3.medium) hourly="0.0416" ;; t3.large) hourly="0.0832" ;;
        m5.xlarge) hourly="0.192" ;; m5.large) hourly="0.096" ;;
        *) hourly="0.10" ;;
      esac
      COST=$(awk -v h="$hourly" 'BEGIN{printf "%.2f", h*24*30}')
      EC2_WASTE=$(awk -v a="$EC2_WASTE" -v b="$COST" 'BEGIN{printf "%.2f", a+b}')
      REPORT_DATA=$(echo "$REPORT_DATA" | jq \
        --arg id "$iid" --arg t "$itype" --arg cpu "$AVG_CPU" --arg c "$COST" \
        '.idle_instances += [{"id":$id,"instance_type":$t,"avg_cpu_pct":$cpu,"monthly_cost_usd":$c}]')
      echo -e "  ${RED}✗${RESET} $(printf '%-22s %-14s avg %s%%  $%s/mo' "$iid" "$itype" "$AVG_CPU" "$COST")"
      if $DELETE; then
        aws $PROFILE_FLAG --region "$REGION" ec2 stop-instances --instance-ids "$iid" > /dev/null && \
          echo -e "      ${YEL}→ Stopped (saving ~\$$COST/mo)${RESET}" || \
          echo -e "      ${RED}→ Failed to stop${RESET}"
      fi
      ((IDLE_FOUND++)) || true
    fi
  done <<< "$INSTANCES"

  if [[ $IDLE_FOUND -eq 0 ]]; then
    echo -e "  ${GRN}✓  All $CHECKED running instance(s) have CPU above threshold${RESET}"
  else
    echo -e "\n  EC2 waste: \$${EC2_WASTE}/mo  ($IDLE_FOUND idle / $CHECKED checked)"
  fi
fi

# ── Summary ───────────────────────────────────────────────────
section "COST WASTE SUMMARY"
TOTAL=$(awk -v v="$VOL_WASTE" -v e="$EIP_WASTE" -v c="$EC2_WASTE" 'BEGIN{printf "%.2f", v+e+c}')
ANNUAL=$(awk -v t="$TOTAL" 'BEGIN{printf "%.2f", t*12}')
printf "  %-30s  %s\n" "Unattached EBS volumes"     "\$$VOL_WASTE/mo"
printf "  %-30s  %s\n" "Unassociated Elastic IPs"   "\$$EIP_WASTE/mo"
printf "  %-30s  %s\n" "Idle EC2 instances"         "\$$EC2_WASTE/mo"
echo   "  ──────────────────────────────────────────────"
printf "  %-30s  %s\n" "TOTAL" "\$$TOTAL/mo  (~\$$ANNUAL/yr)"

if $DELETE; then
  echo -e "\n  ${GRN}${BOLD}Cleanup complete.${RESET}"
else
  echo -e "\n  ${YEL}Dry-run only. Re-run with --delete to remove waste.${RESET}"
fi

# ── Write JSON report ─────────────────────────────────────────
echo "$REPORT_DATA" | jq \
  --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --arg region "$REGION" \
  --arg total "$TOTAL" \
  '. + {"generated_at":$ts,"region":$region,"total_monthly_waste_usd":$total}' \
  > "$REPORT"

echo -e "  Report saved → $REPORT\n"
