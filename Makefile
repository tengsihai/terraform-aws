SHELL := /bin/bash
.DEFAULT_GOAL := help

# `make apply` and `make destroy` exist only to fail loudly. Infrastructure
# changes go through a reviewed plan file and a human, never through automation.

.PHONY: help fmt validate test scan plan plan-offline check-tags quotas verify check clean apply destroy

help:
	@echo "Targets:"
	@echo "  make fmt          format every .tf file in place"
	@echo "  make validate     terraform fmt -check + validate for dev/staging/prod"
	@echo "  make test         terraform test for the modules (mock providers, no AWS calls)"
	@echo "  make scan         checkov scan with the high-risk gate"
	@echo "  make plan         plan all environments (auto offline/online)"
	@echo "  make plan-offline plan all environments with no AWS credentials"
	@echo "  make check-tags   verify base tags on every planned resource (runs an offline plan)"
	@echo "  make quotas       read-only VPC/IGW/EIP/RDS quota pre-check (needs AWS credentials)"
	@echo "  make verify       validate + module tests + tags + offline plan + checkov"
	@echo "  make check        validate + scan"
	@echo "  make clean        remove reports and local terraform state"
	@echo ""
	@echo "  make apply        refuses to run (manual approval required)"

fmt:
	terraform fmt -recursive .

validate:
	./scripts/validate.sh

test:
	@set -e; for module in bastion rds-mysql cloudfront-s3; do \
		echo "==> terraform test: $$module"; \
		terraform -chdir="modules/$$module" init -backend=false -input=false -no-color >/dev/null; \
		terraform -chdir="modules/$$module" test -no-color; \
	done

scan:
	./scripts/scan.sh

plan:
	./scripts/plan.sh

plan-offline:
	./scripts/plan.sh --offline

# 依赖 plan-offline：读取最新 plan 的 JSON，检查每个可打标签的资源是否带上基础标签。
check-tags: plan-offline
	@set -e; for env in dev staging prod; do \
		plan="$$(realpath "$$(ls -t reports/$$env/*.tfplan | head -1)")"; \
		printf '%s: ' "$$env"; \
		terraform -chdir="environments/$$env" show -json "$$plan" | python3 scripts/check-tags.py; \
	done

quotas:
	./scripts/check-quotas.sh

check: validate scan

# 与 CI 等价的一组自动检查：格式/校验、模块测试、标签合规、离线 plan、checkov 高危门禁。
# plan 固定用离线模式，不读取也不修改任何真实 AWS 资源。
verify: validate test check-tags scan

clean:
	rm -rf reports plans
	find . -name '.terraform' -type d -prune -exec rm -rf {} +
	find . \( -name '*.tfstate' -o -name '*.tfstate.backup' -o -name '*.tfplan' \) -delete

apply destroy:
	@bash -c 'source ./scripts/lib.sh; refuse_mutation'
