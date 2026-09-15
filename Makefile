# mlops-workshop — ArgoCD → KServe → LiteLLM on a local kind cluster.
#
#   make help            list targets
#   make image push      build + push elhou/tiny-llm-server (multi-arch)
#   make bootstrap       apply the AppProject + root app (ONCE, by hand)
#   make status          what ArgoCD thinks the world looks like
#   make test            end-to-end chat completion through LiteLLM

SHELL := /bin/bash
.DEFAULT_GOAL := help

DOCKER_USER   ?= elhou
IMAGE_NAME    ?= tiny-llm-server
IMAGE_TAG     ?= 0.1.0
IMAGE         := docker.io/$(DOCKER_USER)/$(IMAGE_NAME):$(IMAGE_TAG)
PLATFORMS     ?= linux/arm64,linux/amd64

CHART_REGISTRY ?= oci://registry-1.docker.io/$(DOCKER_USER)
CHARTS         := model-inference litellm-gateway

CLUSTER       ?= argocd
ARGOCD_NS     ?= argocd
MODEL_NS      ?= models
GATEWAY_NS    ?= ai-gateway
ISVC          ?= tiny-llm
LITELLM_PORT  ?= 4000

##@ Help
.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS=":.*##"; printf "\nUsage: make <target>\n"} \
	     /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2 } \
	     /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

##@ Image
.PHONY: image
image: ## Build the model server for the local arch and load it into Docker
	docker buildx build --load -t $(IMAGE) images/tiny-llm-server

.PHONY: push
push: ## Build multi-arch and push to Docker Hub (needs: docker login -u $(DOCKER_USER))
	docker buildx build --platform $(PLATFORMS) --push -t $(IMAGE) images/tiny-llm-server

.PHONY: image-load
image-load: image ## Load the image straight into kind, skipping Docker Hub entirely
	kind load docker-image $(IMAGE) --name $(CLUSTER)

.PHONY: image-run
image-run: image ## Run the model server locally on :8080 to sanity-check it
	docker run --rm -p 8080:8080 $(IMAGE)

##@ Charts
.PHONY: lint
lint: ## helm lint every chart
	@for c in $(CHARTS); do echo "== $$c"; helm lint charts/$$c; done

.PHONY: template
template: ## Render every chart to stdout
	@for c in $(CHARTS); do echo "### $$c"; helm template $$c charts/$$c; done

.PHONY: publish
publish: ## Package charts and push them to Docker Hub as OCI artifacts
	@mkdir -p dist
	@for c in $(CHARTS); do \
	    helm package charts/$$c -d dist; \
	done
	@for f in dist/*.tgz; do \
	    echo "pushing $$f -> $(CHART_REGISTRY)"; \
	    helm push $$f $(CHART_REGISTRY); \
	done

##@ GitOps
.PHONY: bootstrap
bootstrap: ## Apply the AppProject + root app-of-apps (the only imperative step)
	kubectl apply -f gitops/bootstrap/project.yaml
	kubectl apply -f gitops/bootstrap/root-app.yaml
	@echo "✅ root app applied — ArgoCD owns everything from here. Watch: make status"

.PHONY: status
status: ## Sync/health of every Application, plus the InferenceService
	@kubectl get applications -n $(ARGOCD_NS) -o custom-columns=\
NAME:.metadata.name,WAVE:'.metadata.annotations.argocd\.argoproj\.io/sync-wave',SYNC:.status.sync.status,HEALTH:.status.health.status
	@echo
	@kubectl get inferenceservice -n $(MODEL_NS) 2>/dev/null || echo "(no InferenceService yet)"
	@echo
	@kubectl get pods -n $(MODEL_NS) 2>/dev/null || true
	@kubectl get pods -n $(GATEWAY_NS) 2>/dev/null || true

.PHONY: sync
sync: ## Force ArgoCD to refresh and sync the root app now
	kubectl -n $(ARGOCD_NS) annotate app mlops-root argocd.argoproj.io/refresh=hard --overwrite
	@echo "refresh requested"

##@ Access
.PHONY: ui
ui: ## Port-forward the ArgoCD UI to http://localhost:8080
	@# This ArgoCD runs with server.insecure=true, so argocd-server serves plain
	@# HTTP on its target port. Forwarding :443 and opening https:// sends a TLS
	@# handshake to an HTTP listener, which the server resets. Use the http port.
	@echo "http://localhost:8080  (user: admin, password: make argocd-password)"
	kubectl port-forward -n $(ARGOCD_NS) svc/argocd-server 8080:80

.PHONY: argocd-password
argocd-password: ## Print the initial ArgoCD admin password
	@kubectl -n $(ARGOCD_NS) get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

.PHONY: gateway
gateway: ## Port-forward LiteLLM to localhost:$(LITELLM_PORT)
	kubectl port-forward -n $(GATEWAY_NS) svc/litellm-gateway $(LITELLM_PORT):$(LITELLM_PORT)

##@ Test
.PHONY: test-predictor
test-predictor: ## Hit the KServe predictor directly, bypassing LiteLLM
	kubectl run curl-predictor-$$RANDOM --rm -i --restart=Never -n $(MODEL_NS) \
	  --image=curlimages/curl:8.11.1 -- \
	  curl -s http://$(ISVC)-predictor.$(MODEL_NS).svc.cluster.local/v1/models

.PHONY: test
test: ## End-to-end chat completion through LiteLLM (run `make gateway` first)
	@./scripts/smoke-test.sh

##@ Cleanup
.PHONY: destroy
destroy: ## Delete the root app; ArgoCD prunes every child it created
	kubectl delete -f gitops/bootstrap/root-app.yaml --ignore-not-found
	@echo "root app deleted. CRDs are kept (prune: false on kserve-crd)."
