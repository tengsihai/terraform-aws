# tflint configuration shared by the modules and the environment roots.
#
# `terraform-linters/setup-tflint` runs `tflint --init`, which downloads the
# plugins declared here. Versions are left unpinned on purpose: the CI job
# installs the latest tflint, and the plugin follows it. Pin `version = "x.y.z"`
# below if you need reproducible lint results.

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
  version = "0.50.0"
}

rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

rule "terraform_unused_required_providers" {
  enabled = true
}
