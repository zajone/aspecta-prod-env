# Aspecta production environment.
#
# Every target is a thin wrapper around a script in scripts/, so nothing in this
# file is required to understand or reproduce the environment - `make up` and
# `bash scripts/bootstrap.sh` do exactly the same thing.

SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

# Tools are installed into ./bin by scripts/install-tools.sh, never system-wide.
export PATH := $(CURDIR)/bin:$(PATH)

CLUSTER_NAME ?= aspecta
CONTEXT      := $(CLUSTER_NAME)
APP_NS       ?= aspecta
MON_NS       ?= monitoring
ARGO_NS      ?= argocd
CM_NS        ?= cert-manager
APP_HOST     ?= aspecta.localtest.me
MONITORING   ?= on

.PHONY: help
help: ## Show this help
	@printf '\nAspecta production environment\n\n'
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@printf '\nStart with: make up\n\n'

## ----------------------------------------------------------------- lifecycle
.PHONY: up
up: ## Create the cluster and deploy everything through Argo CD
	@MONITORING=$(MONITORING) scripts/bootstrap.sh

.PHONY: down
down: ## Delete the cluster
	@scripts/teardown.sh

.PHONY: restart
restart: down up ## Delete and recreate the whole environment

.PHONY: tools
tools: ## Install the pinned CLI tools into ./bin
	@scripts/install-tools.sh

.PHONY: preflight
preflight: ## Check that this machine can host the environment
	@scripts/preflight.sh

## -------------------------------------------------------------- build & test
.PHONY: build
build: ## Build both container images and load them into the cluster
	@scripts/build-images.sh

.PHONY: lint
lint: ## Run every static check CI runs (Go, Helm, kubeconform, shell)
	@scripts/lint.sh

.PHONY: hooks
hooks: ## Install the git pre-commit hooks
	@command -v pre-commit >/dev/null || { \
		echo "pre-commit is not installed. Install it with one of:"; \
		echo "  pipx install pre-commit     # recommended, keeps it isolated"; \
		echo "  brew install pre-commit"; \
		echo "  pip install --user pre-commit"; \
		exit 1; }
	@pre-commit install
	@echo "hooks installed; run 'make hooks-run' to check the whole tree now"

.PHONY: hooks-run
hooks-run: ## Run the pre-commit hooks against every file, not just staged ones
	@pre-commit run --all-files

.PHONY: test
test: ## Run the backend unit tests
	@cd apps/backend && go test ./... -cover

.PHONY: verify
verify: ## Verify the running environment end to end
	@scripts/verify.sh

.PHONY: verify-security
verify-security: ## Prove the RBAC, NetworkPolicy and PSA restrictions
	@scripts/verify-security.sh

.PHONY: smoke
smoke: ## Run the chart's in-cluster smoke suite against the release
	@scripts/smoke.sh

.PHONY: test-alert
test-alert: ## Send a synthetic alert through Alertmanager into the UI
	@scripts/fire-test-alert.sh

## ------------------------------------------------------------------ operate
.PHONY: status
status: ## Show what Argo CD thinks of the cluster
	@kubectl --context $(CONTEXT) -n $(ARGO_NS) get applications \
		-o custom-columns='APPLICATION:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision' 2>/dev/null
	@printf '\n'
	@kubectl --context $(CONTEXT) -n $(APP_NS) get deploy,hpa,pdb,ingress 2>/dev/null

.PHONY: sync
sync: ## Force Argo CD to reconcile immediately instead of waiting for the interval
	@kubectl --context $(CONTEXT) -n $(ARGO_NS) annotate application root \
		argocd.argoproj.io/refresh=hard --overwrite >/dev/null
	@echo "refresh requested; watch it with: make status"

.PHONY: logs
logs: ## Tail the backend logs
	@kubectl --context $(CONTEXT) -n $(APP_NS) logs -l app.kubernetes.io/component=backend \
		--tail=50 -f --max-log-requests 6

.PHONY: pods
pods: ## Show resource usage of every pod in the environment
	@kubectl --context $(CONTEXT) top pods -A --sum 2>/dev/null || \
		echo "metrics-server has no data yet; try again in a minute"

.PHONY: urls
urls: ## Print the URLs and credentials of the environment
	@printf '  Application     https://%s\n' '$(APP_HOST)'
	@printf '  Argo CD         https://argocd.localtest.me        admin / %s\n' "$$(kubectl --context $(CONTEXT) -n $(ARGO_NS) get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo '<rotated>')"
	@printf '  Grafana         https://grafana.localtest.me       admin / %s\n' "$$(kubectl --context $(CONTEXT) -n $(MON_NS) get secret grafana-admin -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null || echo '<not installed>')"
	@printf '  Prometheus      https://prometheus.localtest.me\n'
	@printf '  Alertmanager    https://alertmanager.localtest.me\n'
	@printf '\n  HTTPS only - port 80 answers with a redirect. Trust the CA once with: make trust-ca\n'

## ----------------------------------------------------------------------- tls
.PHONY: trust-ca
trust-ca: ## Install this environment's CA into the system trust store (sudo)
	@scripts/trust-ca.sh

.PHONY: untrust-ca
untrust-ca: ## Remove this environment's CA from the system trust store (sudo)
	@UNTRUST=true scripts/trust-ca.sh

.PHONY: ca-cert
ca-cert: ## Print this environment's CA certificate in PEM form
	@kubectl --context $(CONTEXT) -n $(CM_NS) get secret aspecta-ca-root \
		-o jsonpath='{.data.tls\.crt}' | base64 -d

.PHONY: certs
certs: ## Show every certificate in the cluster and when it expires
	@kubectl --context $(CONTEXT) get certificate -A \
		-o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,SECRET:.spec.secretName,RENEWS:.status.renewalTime,EXPIRES:.status.notAfter'

.PHONY: admin-token
admin-token: ## Print the application admin token (for the maintenance endpoint)
	@kubectl --context $(CONTEXT) -n $(APP_NS) get secret aspecta-admin \
		-o jsonpath='{.data.ADMIN_TOKEN}' | base64 -d; echo

.PHONY: hosts-entry
hosts-entry: ## Print the /etc/hosts line to add if *.localtest.me does not resolve
	@printf '127.0.0.1 %s argocd.localtest.me grafana.localtest.me prometheus.localtest.me alertmanager.localtest.me\n' '$(APP_HOST)'

.PHONY: clean-images
clean-images: ## Remove the locally built container images
	@docker images --format '{{.Repository}}:{{.Tag}}' | grep 'aspecta-\(backend\|frontend\)' \
		| xargs -r docker rmi -f || true
	@echo "removed"
