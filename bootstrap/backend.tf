# Bootstrap state lives in the same bucket as the environment states, so an
# accidentally deleted local directory cannot orphan the IAM roles.
#
# terraform init -reconfigure -backend-config=backend.hcl
terraform {
  backend "s3" {}
}
