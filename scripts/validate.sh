#!/usr/bin/env bash
#
# Format check + terraform validate for every environment root and bootstrap.
# Never contacts AWS and never writes remote state.

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

  # A local backend override keeps validation fully offline even when the
  # directory was last initialised against the real S3 backend. Without it,
  # `init -backend=false` still tries to resolve the configured remote backend.
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
