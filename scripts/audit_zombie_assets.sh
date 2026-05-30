#!/usr/bin/env bash
# ============================================================
# FinOps Zombie Asset Auditor (READ-ONLY)
# Detects: unattached EBS volumes, unassociated EIPs,
#          idle EC2 instances, missing CostCenter tags,
#          old EBS snapshots.
# Usage:
#   ./audit_zombie_assets.sh [--region us-east-1] [--profile my-profile]
# ============================================================
set -euo pipefail

REGION="eu-central-1"
PROFILE_FLAG=""
CPU_THRESHOLD=5
SNAPSHOT_AGE_DAYS=90
OUTPUT="audit_report.json"

# ── arg parsing ────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --region)   REGION="$2";          shift 2 ;;
    --profile)  PROFILE_FLAG="--profile $2"; shift 2 ;;
    --output)   OUTPUT="$2";          shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

AWS="aws $PROFILE_FLAG --region $REGION --output text"

# ── colours ───────────────────────────────────────────────────
RED='\033[91m'; GRN='\033[92m'; YEL='\033[93m'
CYA='\033[96m'; BOLD='\033[1m'; RESET='\033[0m'

hdr() { echo -e "\n${BOLD}${CYA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"; \
        echo -e "${BOLD}${CYA}  $1${RESET}"; \
        echo -e "${BOLD}${CYA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"; }

ACCOUNT=$($AWS sts get-caller-identity --query Account)
NOW_EPOCH=$(date +%s)

echo -e "\n${BOLD}FinOps Zombie Asset Auditor  (READ-ONLY)${RESET}"
echo -e "  Account : $ACCOUNT  |  Region : $REGION"
echo -e "  Date    : $(date -u '+%Y-%m-%d %H:%M UTC')"

TOTAL_FINDINGS=0
FINDINGS_JSON="[]"

# ── 1. Unattached EBS Volumes ─────────────────────────────────
hdr "1 / UNATTACHED EBS VOLUMES  (state=available)"
VOLS=$($AWS ec2 describe-volumes \
  --filters Name=status,Values=available \
  --query 'Volumes[*].[VolumeId,VolumeType,Size,AvailabilityZone,CreateTime]' 2>/dev/null || true)

VOL_COUNT=0
if [[ -z "$VOLS" ]]; then
  echo -e "  ${GRN}✓  None found${RESET}"
else
  printf "  %-25s %-6s %5s  %-20s  %s\n" "VolumeId" "Type" "GB" "AZ" "Created"
  printf "  %s\n" "$(printf '─%.0s' {1..80})"
  while IFS=$'\t' read -r vid vtype size az created; do
    [[ -z "$vid" ]] && continue
    RISK="MEDIUM"
    [[ "$vtype" == "io1" || "$vtype" == "io2" ]] && RISK="HIGH"
    echo -e "  ${RED}✗${RESET} $(printf '%-25s %-6s %5s  %-20s  %s' "$vid" "$vtype" "$size" "$az" "$created")"
    FINDINGS_JSON=$(echo "$FINDINGS_JSON" | \
      jq --arg id "$vid" --arg t "$vtype" --argjson s "$size" --arg az "$az" --arg r "$RISK" \
      '. += [{"resource_type":"ebs_volume","id":$id,"volume_type":$t,"size_gb":$s,"az":$az,"risk":$r}]')
    ((VOL_COUNT++)) || true
  done <<< "$VOLS"
  echo -e "\n  ${BOLD}Total:${RESET} $VOL_COUNT unattached volume(s)"
  ((TOTAL_FINDINGS+=VOL_COUNT)) || true
fi

# ── 2. Unassociated Elastic IPs ───────────────────────────────
hdr "2 / UNASSOCIATED ELASTIC IPs"
EIPS=$($AWS ec2 describe-addresses \
  --query 'Addresses[?AssociationId==null].[AllocationId,PublicIp]' 2>/dev/null || true)

EIP_COUNT=0
if [[ -z "$EIPS" ]]; then
  echo -e "  ${GRN}✓  None found${RESET}"
else
  printf "  %-32s %-20s\n" "AllocationId" "PublicIp"
  printf "  %s\n" "$(printf '─%.0s' {1..55})"
  while IFS=$'\t' read -r alloc ip; do
    [[ -z "$alloc" ]] && continue
    echo -e "  ${RED}✗${RESET} $(printf '%-32s %-20s' "$alloc" "$ip")"
    FINDINGS_JSON=$(echo "$FINDINGS_JSON" | \
      jq --arg a "$alloc" --arg ip "$ip" \
      '. += [{"resource_type":"elastic_ip","allocation_id":$a,"public_ip":$ip,"risk":"LOW"}]')
    ((EIP_COUNT++)) || true
  done <<< "$EIPS"
  MONTHLY_COST=$(echo "$EIP_COUNT * 3.60" | bc -l)
  echo -e "\n  ${BOLD}Total:${RESET} $EIP_COUNT EIP(s)  (~\$$MONTHLY_COST/mo)"
  ((TOTAL_FINDINGS+=EIP_COUNT)) || true
fi

# ── 3. Idle EC2 Instances (low CPU) ──────────────────────────
hdr "3 / IDLE EC2 INSTANCES  (avg CPU < ${CPU_THRESHOLD}% / 14 days)"
INSTANCES=$($AWS ec2 describe-instances \
  --filters Name=instance-state-name,Values=running \
  --query 'Reservations[*].Instances[*].[InstanceId,InstanceType,LaunchTime]' 2>/dev/null | \
  grep -v '^None$' || true)

IDLE_COUNT=0; CHECKED=0
END_TIME=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
START_TIME=$(date -u -d '14 days ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
             date -u -v-14d '+%Y-%m-%dT%H:%M:%SZ')

while IFS=$'\t' read -r iid itype launched; do
  [[ -z "$iid" ]] && continue
  ((CHECKED++)) || true
  AVG_CPU=$($AWS cloudwatch get-metric-statistics \
    --namespace AWS/EC2 \
    --metric-name CPUUtilization \
    --dimensions Name=InstanceId,Value="$iid" \
    --start-time "$START_TIME" --end-time "$END_TIME" \
    --period 86400 --statistics Average \
    --query 'average(Datapoints[*].Average)' 2>/dev/null || echo "0")
  AVG_CPU=${AVG_CPU:-0}
  # Compare with threshold using awk (handles floats)
  IS_IDLE=$(awk -v cpu="$AVG_CPU" -v thr="$CPU_THRESHOLD" 'BEGIN{print (cpu+0 < thr+0) ? "yes" : "no"}')
  if [[ "$IS_IDLE" == "yes" ]]; then
    echo -e "  ${RED}✗${RESET}  $(printf '%-22s %-14s avg %5.1f%%  %s' "$iid" "$itype" "$AVG_CPU" "$launched")"
    FINDINGS_JSON=$(echo "$FINDINGS_JSON" | \
      jq --arg id "$iid" --arg t "$itype" --arg c "$AVG_CPU" \
      '. += [{"resource_type":"ec2_instance","id":$id,"instance_type":$t,"avg_cpu":$c,"risk":"HIGH"}]')
    ((IDLE_COUNT++)) || true
  fi
done <<< "$INSTANCES"

if [[ $IDLE_COUNT -eq 0 ]]; then
  echo -e "  ${GRN}✓  All $CHECKED instance(s) have CPU above threshold${RESET}"
else
  echo -e "\n  ${BOLD}Total:${RESET} $IDLE_COUNT idle instance(s) / $CHECKED checked"
  ((TOTAL_FINDINGS+=IDLE_COUNT)) || true
fi

# ── 4. Missing CostCenter Tag ────────────────────────────────
hdr "4 / INSTANCES MISSING CostCenter TAG"
ALL_INST=$($AWS ec2 describe-instances \
  --filters 'Name=instance-state-name,Values=running,stopped' \
  --query 'Reservations[*].Instances[*].[InstanceId,InstanceType,State.Name,Tags[?Key==`CostCenter`].Value|[0]]' \
  2>/dev/null || true)

NOTAG_COUNT=0
while IFS=$'\t' read -r iid itype state cc; do
  [[ -z "$iid" ]] && continue
  if [[ -z "$cc" || "$cc" == "None" ]]; then
    echo -e "  ${YEL}!${RESET}  $(printf '%-22s %-14s %-12s  no CostCenter tag' "$iid" "$itype" "$state")"
    FINDINGS_JSON=$(echo "$FINDINGS_JSON" | \
      jq --arg id "$iid" --arg t "$itype" --arg s "$state" \
      '. += [{"resource_type":"ec2_instance","id":$id,"instance_type":$t,"state":$s,"violation":"missing CostCenter","risk":"MEDIUM"}]')
    ((NOTAG_COUNT++)) || true
  fi
done <<< "$ALL_INST"

if [[ $NOTAG_COUNT -eq 0 ]]; then
  echo -e "  ${GRN}✓  All instances carry a CostCenter tag${RESET}"
else
  echo -e "\n  ${BOLD}Total:${RESET} $NOTAG_COUNT instance(s) missing CostCenter tag"
  ((TOTAL_FINDINGS+=NOTAG_COUNT)) || true
fi

# ── 5. Old EBS Snapshots ─────────────────────────────────────
hdr "5 / OLD EBS SNAPSHOTS  (> $SNAPSHOT_AGE_DAYS days)"
SNAPS=$($AWS ec2 describe-snapshots --owner-ids self \
  --query 'Snapshots[*].[SnapshotId,VolumeId,VolumeSize,StartTime]' 2>/dev/null || true)

SNAP_COUNT=0
CUTOFF_EPOCH=$(date -d "$SNAPSHOT_AGE_DAYS days ago" +%s 2>/dev/null || \
               date -v-${SNAPSHOT_AGE_DAYS}d +%s)

while IFS=$'\t' read -r sid vid size stime; do
  [[ -z "$sid" ]] && continue
  SNAP_EPOCH=$(date -d "$stime" +%s 2>/dev/null || date -j -f '%Y-%m-%dT%H:%M:%S' "${stime%.*}" +%s 2>/dev/null || echo 0)
  if [[ $SNAP_EPOCH -lt $CUTOFF_EPOCH ]]; then
    AGE=$(( (NOW_EPOCH - SNAP_EPOCH) / 86400 ))
    echo -e "  ${YEL}!${RESET}  $(printf '%-25s %-25s %4sGB  %sd' "$sid" "$vid" "$size" "$AGE")"
    FINDINGS_JSON=$(echo "$FINDINGS_JSON" | \
      jq --arg id "$sid" --arg vid "$vid" --argjson s "$size" --argjson age "$AGE" \
      '. += [{"resource_type":"ebs_snapshot","id":$id,"volume_id":$vid,"size_gb":$s,"age_days":$age,"risk":"LOW"}]')
    ((SNAP_COUNT++)) || true
  fi
done <<< "$SNAPS"

if [[ $SNAP_COUNT -eq 0 ]]; then
  echo -e "  ${GRN}✓  No snapshots older than $SNAPSHOT_AGE_DAYS days${RESET}"
else
  echo -e "\n  ${BOLD}Total:${RESET} $SNAP_COUNT old snapshot(s)"
  ((TOTAL_FINDINGS+=SNAP_COUNT)) || true
fi

# ── Executive Summary ─────────────────────────────────────────
hdr "EXECUTIVE SUMMARY"
echo -e "  ${BOLD}TOTAL findings : $TOTAL_FINDINGS${RESET}"
echo -e "\n  Recommended actions:"
echo    "    1. Run garbage_collector.sh --delete to remove EBS/EIP waste"
echo    "    2. Tag all untagged instances with CostCenter immediately"
echo    "    3. Stop or rightsize idle EC2 instances"
echo    "    4. Review and delete orphaned snapshots"

# ── Write JSON report ─────────────────────────────────────────
echo "$FINDINGS_JSON" | jq \
  --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --arg acct "$ACCOUNT" \
  --arg reg "$REGION" \
  --argjson total "$TOTAL_FINDINGS" \
  '{"generated_at":$ts,"account_id":$acct,"region":$reg,"total_findings":$total,"findings":.}' \
  > "$OUTPUT"

echo -e "\n  ${CYA}Report saved → $OUTPUT${RESET}\n"
