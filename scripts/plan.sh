#!/usr/bin/env bash
#
# 为一个或多个环境生成可评审的 plan。
#
#   scripts/plan.sh                 # 全部环境
#   scripts/plan.sh prod            # 只做单个环境
#   scripts/plan.sh --offline dev   # 不需要 AWS 账户
#
# 本脚本从不执行任何 apply。它产出的 plan 文件是人工审批环节的输入，
# 不是自动化的输入。

set -euo pipefail
# shellcheck source=lib.sh source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/plan.sh [--offline|--online] [--all] [environment...]

  --offline   run without AWS credentials; state is local and every resource
              is planned as "new". Use for CI syntax/graph checks only.
  --online    require AWS credentials and a backend.hcl; the plan is refreshed
              against the real account and is suitable for review.
  (default)   offline when no credentials are present, online otherwise.

  environment one of: dev, staging, prod (default: all three)
EOF
}

TF="$(find_terraform)"

MODE="auto"
REQUESTED=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --offline) MODE="offline" ;;
    --online) MODE="online" ;;
    --all) ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      usage >&2
      die "unknown flag: $1"
      ;;
    *)
      REQUESTED+=("$1")
      ;;
  esac
  shift
done

if [ "${#REQUESTED[@]}" -eq 0 ]; then
  REQUESTED=("${ALL_ENVIRONMENTS[@]}")
fi

for env in "${REQUESTED[@]}"; do
  validate_environment_name "${env}"
done

if [ "${MODE}" = "auto" ]; then
  if has_aws_credentials; then
    MODE="online"
  else
    MODE="offline"
    warn "no AWS credentials detected - running in OFFLINE mode (plans are graph checks, not account-validated)"
  fi
fi

if [ "${MODE}" = "offline" ] && has_aws_credentials; then
  warn "AWS credentials are present but offline mode was requested; no API call will be made"
fi

mkdir -p "${REPORTS_DIR}"

cleanup_env() {
  rm -f "${ROOT_DIR}/environments/$1/backend_override.tf"
}

# 即使 plan 中途失败，也要清掉临时的后端 override。
# （macOS 自带 bash 3.2，set -u 下不能展开空数组，所以这里用循环兜住）
cleanup_all() {
  for e in "${REQUESTED[@]}"; do
    cleanup_env "${e}"
  done
}
trap cleanup_all EXIT

summaries=()

for env in "${REQUESTED[@]}"; do
  env_dir="environments/${env}"
  out_dir="${REPORTS_DIR}/${env}"
  mkdir -p "${out_dir}"

  stamp="$(date +%Y%m%dT%H%M%S)"
  report="${out_dir}/plan-${stamp}.txt"
  planfile="${out_dir}/plan-${stamp}.tfplan"
  latest="${out_dir}/plan-latest.txt"

  log "planning ${env} (mode: ${MODE})"

  if [ "${MODE}" = "offline" ]; then
    # 用本地的后端 override，让 `terraform plan` 不去碰远端 state，
    # 同时也不必修改已提交的 backend.tf。用完在下面删掉。
    # 必须带 -reconfigure：工作目录可能已经初始化成真实的 S3 后端，
    # 离线 plan 要忽略它。
    cat >"${ROOT_DIR}/${env_dir}/backend_override.tf" <<'EOF'
terraform {
  backend "local" {}
}
EOF
    "${TF}" -chdir="${ROOT_DIR}/${env_dir}" init -reconfigure -input=false -no-color >/dev/null
    var_args=(-var=offline_mode=true)
  else
    [ -f "${ROOT_DIR}/${env_dir}/backend.hcl" ] \
      || die "environments/${env}/backend.hcl missing. Copy backend.hcl.example and fill it in."

    # SDK 看不见 AWS CLI 的 "login" 会话，先把会话凭证导出。
    ensure_terraform_credentials

    if command -v aws >/dev/null 2>&1; then
      caller_account="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
      expected_account="$(sed -nE 's/^[[:space:]]*aws_account_id[[:space:]]*=[[:space:]]*"([0-9]{12})".*/\1/p' "${ROOT_DIR}/${env_dir}/env.tfvars" | head -1)"
      if [ -n "${caller_account}" ] && [ "${caller_account}" != "${expected_account}" ]; then
        die "AWS caller account ${caller_account} does not match aws_account_id ${expected_account} in environments/${env}/env.tfvars. Fix the placeholder before planning against a real account."
      fi
    fi

    "${TF}" -chdir="${ROOT_DIR}/${env_dir}" init -reconfigure -backend-config=backend.hcl -input=false -no-color >/dev/null
    var_args=(-var=offline_mode=false)
  fi

  set +e
  "${TF}" -chdir="${ROOT_DIR}/${env_dir}" plan \
    -var-file=env.tfvars \
    "${var_args[@]}" \
    -input=false \
    -no-color \
    -detailed-exitcode \
    -out="${planfile}" >"${report}" 2>&1
  plan_status=$?
  set -e

  cleanup_env "${env}"

  case "${plan_status}" in
    0)
      summary="no changes"
      ;;
    2)
      summary="$(grep -E '^Plan: ' "${report}" | tail -1)"
      ;;
    *)
      cat "${report}" >&2
      die "terraform plan failed for ${env} (exit ${plan_status})"
      ;;
  esac

  cp "${report}" "${latest}"
  summaries+=("${env}: ${summary}   -> ${report}")
done

log "plan summary"
printf '%s\n' "${summaries[@]}"

cat <<'EOF'

No changes were applied. `terraform apply` is deliberately not scriptable in
this repository - see the manual approval procedure in README.md.
EOF
