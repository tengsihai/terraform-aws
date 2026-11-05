#!/usr/bin/env bash
#
# Shared helpers for the scripts in this directory.
#
# Everything here is read-only: no script in this repository may run
# `terraform apply` or `terraform destroy`. See docs/ARCHITECTURE.md.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Used by the scripts that source this file (plan.sh, scan.sh), never by lib.sh.
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

# True when the AWS SDK can find usable credentials.
has_aws_credentials() {
  if [ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ]; then
    return 0
  fi
  if [ -n "${AWS_PROFILE:-}" ] || [ -f "${HOME}/.aws/credentials" ]; then
    return 0
  fi
  return 1
}

# Terraform's AWS SDK reads ~/.aws/credentials and ~/.aws/config, but the
# modern AWS CLI "login" session stores credentials in a format the SDK cannot
# read (aws configure list shows them as type "login"). Export the current
# session into the environment so local runs work without copying long-lived
# keys around.
ensure_terraform_credentials() {
  if [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
    return 0
  fi
  if command -v aws >/dev/null 2>&1 \
    && aws configure export-credentials --format env >/dev/null 2>&1; then
    eval "$(aws configure export-credentials --format env)"
  fi
}

# Rejects any environment name that is not one of the three managed roots.
validate_environment_name() {
  local env="$1"
  for known in "${ALL_ENVIRONMENTS[@]}"; do
    [ "${env}" = "${known}" ] && return 0
  done
  die "unknown environment '${env}'. Expected one of: ${ALL_ENVIRONMENTS[*]}"
}

# Hard block on the two commands that change real infrastructure.
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
