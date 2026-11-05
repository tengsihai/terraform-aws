###############################################################################
# Remote state
#
# Nothing here is committed with real values. Initialise with:
#
#   terraform init -backend-config=backend.hcl
#
# and copy backend.hcl.example to backend.hcl (git-ignored). For syntax-only
# checks with no AWS account, use `terraform init -backend=false`.
###############################################################################

terraform {
  backend "s3" {}
}
