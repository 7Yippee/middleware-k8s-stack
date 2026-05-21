# Convenience entrypoints. All commands delegate to scripts/ so behavior stays
# consistent with running the scripts directly.

SHELL := /usr/bin/env bash
ENVIRONMENT ?= dev
NAMESPACE   ?= middleware
COMPONENTS  ?= all

.PHONY: help doctor pull-charts mirror quickstart deploy status logs uninstall secrets \
        offline-export offline-import dry-run

help:
	@awk 'BEGIN{FS=":.*##"; printf "Targets:\n"} /^[a-zA-Z_-]+:.*##/ { printf "  %-16s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

doctor: ## Run preflight checks against the current kube-context
	NAMESPACE=$(NAMESPACE) ENVIRONMENT=$(ENVIRONMENT) scripts/doctor.sh

pull-charts: ## Cache helm charts under ./charts/
	scripts/pull-charts.sh $(COMPONENTS)

mirror: ## Mirror container images to your private registry
	scripts/mirror-images.sh $(COMPONENTS)

quickstart: ## Preflight + optional secrets + deploy
	ENVIRONMENT=$(ENVIRONMENT) NAMESPACE=$(NAMESPACE) STORAGE_CLASS=$(STORAGE_CLASS) MIRROR_IMAGES=$(MIRROR_IMAGES) GEN_SECRETS=$(GEN_SECRETS) scripts/quickstart.sh $(COMPONENTS)

deploy: ## Deploy components (COMPONENTS=all by default)
	ENVIRONMENT=$(ENVIRONMENT) NAMESPACE=$(NAMESPACE) STORAGE_CLASS=$(STORAGE_CLASS) MIRROR_IMAGES=$(MIRROR_IMAGES) TIMEOUT=$(TIMEOUT) HARDENING=$(HARDENING) USE_LOCAL_CHARTS=$(USE_LOCAL_CHARTS) scripts/deploy.sh $(COMPONENTS)

dry-run: ## helm template only, no apply
	ENVIRONMENT=$(ENVIRONMENT) NAMESPACE=$(NAMESPACE) STORAGE_CLASS=$(STORAGE_CLASS) HARDENING=$(HARDENING) USE_LOCAL_CHARTS=$(USE_LOCAL_CHARTS) DRY_RUN=true scripts/deploy.sh $(COMPONENTS)

status: ## Show helm releases, pods, svc, pvc
	NAMESPACE=$(NAMESPACE) scripts/status.sh

logs: ## Tail logs for a component (COMPONENTS=<one>)
	NAMESPACE=$(NAMESPACE) scripts/logs.sh $(COMPONENTS)

uninstall: ## Uninstall releases (set DELETE_PVC=true to drop data)
	NAMESPACE=$(NAMESPACE) scripts/uninstall.sh $(COMPONENTS)

secrets: ## Generate/rotate auth secrets (set ROTATE=true to overwrite)
	NAMESPACE=$(NAMESPACE) scripts/gen-secrets.sh

offline-export: ## Save image bundle for air-gapped transfer
	EXPORT_DIR=$(PWD)/offline-bundle scripts/mirror-images.sh $(COMPONENTS)

offline-import: ## Push a previously-exported bundle to the target registry
	IMPORT_FROM=$(PWD)/offline-bundle scripts/mirror-images.sh $(COMPONENTS)
