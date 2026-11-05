SHELL := /bin/bash
.DEFAULT_GOAL := help

# `make apply` and `make destroy` exist only to fail loudly. Infrastructure
# changes go through a reviewed plan file and a human, never through automation.

.PHONY: help fmt validate validate-all scan plan plan-offline check clean apply destroy

help:
	@echo "Targets:"
	@echo "  make fmt          format every .tf file in place"
	@echo "  make validate     terraform fmt -check + validate for dev/staging/prod"
	@echo "  make scan         checkov scan with the high-risk gate"
	@echo "  make plan         plan all environments (auto offline/online)"
	@echo "  make plan-offline plan all environments with no AWS credentials"
	@echo "  make check        validate + scan"
	@echo "  make clean        remove reports and local terraform state"
	@echo ""
	@echo "  make apply        refuses to run (manual approval required)"

fmt:
	terraform fmt -recursive .

validate:
	./scripts/validate.sh

scan:
	./scripts/scan.sh

plan:
	./scripts/plan.sh

plan-offline:
	./scripts/plan.sh --offline

check: validate scan

clean:
	rm -rf reports plans
	find . -name '.terraform' -type d -prune -exec rm -rf {} +
	find . \( -name '*.tfstate' -o -name '*.tfstate.backup' -o -name '*.tfplan' \) -delete

apply destroy:
	@bash -c 'source ./scripts/lib.sh; refuse_mutation'
