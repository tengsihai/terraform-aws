#!/usr/bin/env bash
#
# Read-only quota pre-check (R-18).
#
# 在 apply 之前确认账户/区域的 VPC、Internet 网关、EIP、RDS 配额还够用。
# 本脚本只调用 Describe/Get 类 API，不做任何写操作。
#
#   scripts/check-quotas.sh                 # 单个环境（默认）
#   ENVIRONMENTS=3 scripts/check-quotas.sh  # 三个环境部署在同一账户时
#   AWS_REGION=ap-northeast-1 scripts/check-quotas.sh
#
# 退出码：0 = 配额充足；1 = 有配额不足；2 = 无法读取配额或用量。

set -euo pipefail
# shellcheck source=lib.sh source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REGION="${AWS_REGION:-ap-northeast-1}"
ENVIRONMENTS="${ENVIRONMENTS:-1}"

# 每个环境计划创建的资源数量（与当前架构保持一致）。
PER_ENV_VPCS=1
PER_ENV_IGWS=1
PER_ENV_EIPS=0
PER_ENV_RDS=1

usage() {
  cat <<'EOF'
Usage: ENVIRONMENTS=<n> AWS_REGION=<region> scripts/check-quotas.sh

  ENVIRONMENTS  number of environments that will share this account/region (default 1)
  AWS_REGION    region to check (default ap-northeast-1)

Read-only: uses Describe*/GetServiceQuota only.
EOF
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
  "") ;;
  *)
    usage >&2
    die "unknown argument: $1"
    ;;
esac

command -v aws >/dev/null 2>&1 || die "aws CLI not found"
has_aws_credentials || die "no AWS credentials found; this check must run against the target account"

quota() {
  aws service-quotas get-service-quota \
    --region "${REGION}" \
    --service-code "$1" \
    --quota-code "$2" \
    --query 'Quota.Value' --output text
}

failures=0

check() {
  local label="$1" quota_value="$2" used="$3" planned="$4"
  local total headroom status
  total=$((used + planned))

  if ! awk -v q="${quota_value}" -v t="${total}" 'BEGIN { exit !(t > q) }'; then
    headroom=$(awk -v q="${quota_value}" -v t="${total}" 'BEGIN { printf "%.0f", q - t }')
    status="OK"
  else
    headroom=0
    status="FAIL"
    failures=$((failures + 1))
  fi

  printf '%-32s quota=%-6s used=%-4s planned=%-3s headroom=%-4s %s\n' \
    "${label}" "${quota_value}" "${used}" "${planned}" "${headroom}" "${status}"
}

echo "region=${REGION} environments=${ENVIRONMENTS} (read-only)"

vpcs_used=$(aws ec2 describe-vpcs --region "${REGION}" --query 'length(Vpcs)' --output text)
igws_used=$(aws ec2 describe-internet-gateways --region "${REGION}" --query 'length(InternetGateways)' --output text)
eips_used=$(aws ec2 describe-addresses --region "${REGION}" --query 'length(Addresses)' --output text)
rds_used=$(aws rds describe-db-instances --region "${REGION}" --query 'length(DBInstances)' --output text)

check "VPCs per Region" "$(quota vpc L-F678F1CE)" "${vpcs_used}" "$((PER_ENV_VPCS * ENVIRONMENTS))"
check "Internet gateways per Region" "$(quota vpc L-A4707A72)" "${igws_used}" "$((PER_ENV_IGWS * ENVIRONMENTS))"
check "EC2-VPC Elastic IPs" "$(quota ec2 L-0263D0A3)" "${eips_used}" "$((PER_ENV_EIPS * ENVIRONMENTS))"
check "RDS DB instances" "$(quota rds L-7B6409FD)" "${rds_used}" "$((PER_ENV_RDS * ENVIRONMENTS))"

if [ "${failures}" -ne 0 ]; then
  die "${failures} quota check(s) failed; request a quota increase before apply"
fi

log "quota headroom is sufficient"
