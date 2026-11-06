#!/usr/bin/env bash
#
# 对所有环境根目录和 bootstrap 做格式检查 + terraform validate。
# 不访问 AWS，也不写远端 state。

set -euo pipefail
# shellcheck source=lib.sh source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TF="$(find_terraform)"

ROOTS=()
for env in "${ALL_ENVIRONMENTS[@]}"; do
  validate_environment_name "${env}"
  ROOTS+=("environments/${env}")
done
ROOTS+=("bootstrap")

cleanup_overrides() {
  for root in "${ROOTS[@]}"; do
    rm -f "${ROOT_DIR}/${root}/backend_override.tf"
  done
}
trap cleanup_overrides EXIT

log "terraform fmt -check (whole repository)"
(
  cd "${ROOT_DIR}"
  "${TF}" fmt -check -recursive -diff .
) || die "formatting drift detected. Run: terraform fmt -recursive ."

for root in "${ROOTS[@]}"; do
  log "terraform validate: ${root}"

  # 用本地的后端 override 让校验完全离线，即使这个目录上次是
  # 对着真实 S3 后端初始化的。没有它的话，`init -backend=false`
  # 仍会尝试解析已配置的远端后端。
  cat >"${ROOT_DIR}/${root}/backend_override.tf" <<'EOF'
terraform {
  backend "local" {}
}
EOF

  "${TF}" -chdir="${ROOT_DIR}/${root}" init -reconfigure -input=false -no-color >/dev/null
  "${TF}" -chdir="${ROOT_DIR}/${root}" validate -no-color

  rm -f "${ROOT_DIR}/${root}/backend_override.tf"
done

log "All roots validated."
