SHELL := /bin/bash
.DEFAULT_GOAL := help
TF_ENV ?= dev
TF_DIR := terraform/live/$(TF_ENV)
CLUSTER_NAME := garden-$(TF_ENV)
AWS_REGION ?= us-east-1

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-28s\033[0m %s\n", $$1, $$2}'

.PHONY: preflight
preflight: ## Validate AWS/kubectl/gh/terraform/helm/yq tooling
	@bash scripts/preflight.sh

.PHONY: bootstrap-state
bootstrap-state: ## One-shot: create S3 state bucket + DynamoDB lock table
	@bash scripts/bootstrap-state.sh

.PHONY: init
init: ## Run terraform init for $(TF_ENV)
	cd $(TF_DIR) && terraform init

.PHONY: fmt
fmt: ## Run terraform fmt across all .tf files
	terraform fmt -recursive terraform/

.PHONY: validate
validate: ## Run terraform validate for $(TF_ENV)
	cd $(TF_DIR) && terraform validate

.PHONY: plan-dev
plan-dev: ## terraform plan for dev
	$(MAKE) plan TF_ENV=dev

.PHONY: plan-uat
plan-uat: ## terraform plan for uat
	$(MAKE) plan TF_ENV=uat

.PHONY: plan-prod
plan-prod: ## terraform plan for prod
	$(MAKE) plan TF_ENV=prod

.PHONY: plan
plan: ## terraform plan for $(TF_ENV)
	cd $(TF_DIR) && terraform init -upgrade && terraform plan -out=tfplan

.PHONY: apply-dev
apply-dev: ## terraform apply for dev
	$(MAKE) apply TF_ENV=dev

.PHONY: apply-uat
apply-uat: ## terraform apply for uat
	$(MAKE) apply TF_ENV=uat

.PHONY: apply-prod
apply-prod: ## terraform apply for prod
	$(MAKE) apply TF_ENV=prod

.PHONY: apply
apply: ## terraform apply for $(TF_ENV)
	cd $(TF_DIR) && terraform apply tfplan

.PHONY: destroy
destroy: ## terraform destroy for $(TF_ENV) — confirms before running
	@echo "WARNING: this destroys all infra in $(TF_ENV)."
	@read -p "Type the env name to confirm: " CONFIRM && [ "$$CONFIRM" = "$(TF_ENV)" ] || (echo "abort" && exit 1)
	cd $(TF_DIR) && terraform destroy

.PHONY: kubeconfig
kubeconfig: ## Update kubectl context for $(TF_ENV)
	aws eks update-kubeconfig --region $(AWS_REGION) --name $(CLUSTER_NAME) --alias $(CLUSTER_NAME)

.PHONY: argocd-bootstrap
argocd-bootstrap: ## kubectl apply the Argo CD root app
	kubectl --context $(CLUSTER_NAME) apply -f gitops/bootstrap/argocd-root-app.yaml

.PHONY: argocd-login
argocd-login: ## Get admin password and port-forward Argo CD
	@bash scripts/argocd-login.sh

.PHONY: helm-lint
helm-lint: ## Lint the microservice chart
	helm lint gitops/charts/microservice

.PHONY: helm-template
helm-template: ## Render the microservice chart with dev values
	helm template demo gitops/charts/microservice -f gitops/envs/dev/values.yaml

.PHONY: yaml-validate
yaml-validate: ## kubectl --dry-run all manifests
	@for f in $$(find gitops -name '*.yaml' -not -path '*/charts/*'); do \
		echo "validating $$f"; \
		kubectl apply --dry-run=client -f $$f > /dev/null || echo "FAILED: $$f"; \
	done
