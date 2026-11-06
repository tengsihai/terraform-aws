#!/usr/bin/env bash
#
# 本目录下各脚本共用的辅助函数。
#
# 这里的一切都是只读的：本仓库的任何脚本都不得执行
# `terraform apply` 或 `terraform destroy`。参见 docs/ARCHITECTURE.md。

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 供 source 本文件的脚本使用（plan.sh、scan.sh），lib.sh 自身不直接用到。
# shellcheck disable=SC2034
REPORTS_DIR="${ROOT_DIR}/reports"
ALL_ENVIRONMENTS=(dev staging prod)

log() {
  printf '\n\033[1m==> %s\033[0m\n' "$*"
}

warn() {
  printf '\033[1;33mWARN: %s\033[0m\n' "$*" >&2
}

die() {
  printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2
  exit 1
}

find_terraform() {
  if command -v terraform >/dev/null 2>&1; then
    command -v terraform
  elif [ -x "${HOME}/.local/bin/terraform" ]; then
    echo "${HOME}/.local/bin/terraform"
  else
    die "terraform not found. Install it from https://developer.hashicorp.com/terraform/install"
  fi
}

find_checkov() {
  if command -v checkov >/dev/null 2>&1; then
    command -v checkov
  elif [ -x "${HOME}/.local/venvs/checkov/bin/checkov" ]; then
    echo "${HOME}/.local/venvs/checkov/bin/checkov"
  else
    die "checkov not found. Install it with: python3 -m venv ~/.local/venvs/checkov && ~/.local/venvs/checkov/bin/pip install checkov"
  fi
}

# AWS SDK 能拿到可用凭证时返回真。
has_aws_credentials() {
  if [ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ]; then
    return 0
  fi
  if [ -n "${AWS_PROFILE:-}" ] || [ -f "${HOME}/.aws/credentials" ]; then
    return 0
  fi
  # AWS CLI 的 "login" 会话不写凭证文件，上面的检查会漏掉它，
  # 导致 plan.sh 静默退化成离线模式。这里改成直接问 CLI
  # 能不能导出一份会话凭证。
  if command -v aws >/dev/null 2>&1 \
    && aws configure export-credentials --format env >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# Terraform 的 AWS SDK 会读 ~/.aws/credentials 和 ~/.aws/config，但新版
# AWS CLI 的 "login" 会话存的格式 SDK 读不懂（aws configure list 里
# credential type 显示为 login）。把当前会话导出到环境变量，
# 这样本地运行不必到处复制长期密钥。
ensure_terraform_credentials() {
  if [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
    return 0
  fi
  if command -v aws >/dev/null 2>&1 \
    && aws configure export-credentials --format env >/dev/null 2>&1; then
    eval "$(aws configure export-credentials --format env)"
  fi
}

# 拒绝三个受管环境之外的任何环境名。
validate_environment_name() {
  local env="$1"
  for known in "${ALL_ENVIRONMENTS[@]}"; do
    [ "${env}" = "${known}" ] && return 0
  done
  die "unknown environment '${env}'. Expected one of: ${ALL_ENVIRONMENTS[*]}"
}

# 硬性拦截两个会改变真实基础设施的命令。
refuse_mutation() {
  cat >&2 <<'EOF'
ERROR: applying changes is intentionally not automated.

  `terraform apply` and `terraform destroy` must be run by a human, from a
  reviewed plan file, after explicit approval. See docs/RISKS.md (R-01) and
  the "Manual approval procedure" section of README.md.

  Reproduce the reviewed plan with:  make plan
EOF
  exit 1
}
