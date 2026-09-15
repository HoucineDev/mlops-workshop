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
PLATFORMS     ?= linux/arm64,linux/amd64

# ── model catalogue ──────────────────────────────────────────────────────────
# One image per model, the GGUF baked in. Pick with MODEL=<name>:
#   make image MODEL=qwen3-0.6b
#
# MODEL_SHA256 is the sha256 of the LFS object; get it for a new model with
#   curl -sIL <url> | grep -i x-linked-etag
# Leaving it wrong is safe — the build fails the checksum rather than shipping
# unverified weights.
MODEL ?= smollm2-135m

ifeq ($(MODEL),smollm2-135m)
MODEL_URL    := https://huggingface.co/bartowski/SmolLM2-135M-Instruct-GGUF/resolve/main/SmolLM2-135M-Instruct-Q4_K_M.gguf
MODEL_SHA256 := 2e8040ceae7815abe0dcb3540b9995eaa1fa0d2ca9e797d0a635ae4433c68c2d
endif
ifeq ($(MODEL),qwen3-0.6b)
MODEL_URL    := https://huggingface.co/unsloth/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q4_K_M.gguf
MODEL_SHA256 := ac2d97712095a558e31573f62f466a3f9d93990898b0ec79d7c974c1780d524a
endif
ifeq ($(MODEL),qwen2.5-0.5b)
MODEL_URL    := https://huggingface.co/bartowski/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/Qwen2.5-0.5B-Instruct-Q4_K_M.gguf
MODEL_SHA256 := 6eb923e7d26e9cea28811e1a8e852009b21242fb157b26149d3b188f3a8c8653
endif

ifeq ($(strip $(MODEL_URL)),)
$(error unknown MODEL "$(MODEL)" — see the catalogue at the top of the Makefile)
endif

# The original SmolLM2 image predates this scheme and is published as plain
# 0.1.0; every other model is tagged <model>-<version>.
VERSION       ?= 0.1.0
ifeq ($(MODEL),smollm2-135m)
IMAGE_TAG     ?= $(VERSION)
else
IMAGE_TAG     ?= $(MODEL)-$(VERSION)
endif
IMAGE         := docker.io/$(DOCKER_USER)/$(IMAGE_NAME):$(IMAGE_TAG)
BUILD_ARGS    := --build-arg MODEL_URL=$(MODEL_URL) --build-arg MODEL_SHA256=$(MODEL_SHA256)

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
image: ## Build the model server for the local arch (MODEL=<name> to pick one)
	docker buildx build --load -t $(IMAGE) $(BUILD_ARGS) images/tiny-llm-server

.PHONY: push
push: ## Build multi-arch and push to Docker Hub (needs: docker login -u $(DOCKER_USER))
	docker buildx build --platform $(PLATFORMS) --push -t $(IMAGE) $(BUILD_ARGS) images/tiny-llm-server

.PHONY: image-load
image-load: image ## Load the image straight into kind, skipping Docker Hub entirely
	kind load docker-image $(IMAGE) --name $(CLUSTER)

.PHONY: image-run
image-run: image ## Run the model server locally on :8080 to sanity-check it
	docker run --rm -p 8080:8080 $(IMAGE)

.PHONY: models
models: ## List the models in the catalogue
	@echo "  smollm2-135m   105 MB  fast, frequently wrong"
	@echo "  qwen3-0.6b     378 MB  reasoning model — needs LLAMA_ARG_REASONING=off"
	@echo "  qwen2.5-0.5b   379 MB  solid non-reasoning alternative"
	@echo
	@echo "  build one:  make image MODEL=qwen3-0.6b"

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

.PHONY: ingress
ingress: ## One front door for BOTH UIs on :8080 (use when host ports 80/443 are unmapped)
	@echo "  ArgoCD  -> http://argocd.localtest.me:8080"
	@echo "  LiteLLM -> http://litellm.localtest.me:8080"
	@echo "  (*.localtest.me resolves to 127.0.0.1 — no /etc/hosts entry needed)"
	kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 8080:80

.PHONY: ingress-check
ingress-check: ## Are host ports 80/443 mapped into the kind node?
	@echo "kind node port mappings:"
	@docker port $(CLUSTER)-control-plane || true
	@echo
	@if docker port $(CLUSTER)-control-plane 2>/dev/null | grep -q '^80/tcp'; then \
	    echo "✅ port 80 is mapped — http://argocd.localtest.me works directly"; \
	else \
	    echo "❌ port 80 is NOT mapped — Ingress is unreachable from macOS."; \
	    echo "   Either run 'make ingress' (port-forward), or recreate the"; \
	    echo "   cluster with 'make cluster-recreate' to map 80/443."; \
	fi

##@ Test
.PHONY: test-predictor
test-predictor: ## Hit the KServe predictor directly, bypassing LiteLLM
	kubectl run curl-predictor-$$RANDOM --rm -i --restart=Never -n $(MODEL_NS) \
	  --image=curlimages/curl:8.11.1 -- \
	  curl -s http://$(ISVC)-predictor.$(MODEL_NS).svc.cluster.local/v1/models

.PHONY: test
test: ## End-to-end chat completion through LiteLLM (run `make gateway` first)
	@./scripts/smoke-test.sh

##@ Cluster
.PHONY: cluster-recreate
cluster-recreate: ## DESTRUCTIVE. Recreate the kind cluster with host ports 80/443 mapped
	@echo "This DELETES the kind cluster '$(CLUSTER)' and everything in it,"
	@echo "including ArgoCD. You then reinstall ArgoCD and run 'make bootstrap',"
	@echo "and ArgoCD rebuilds every workload from Git."
	@printf "Type the cluster name to confirm: "; read ans; [ "$$ans" = "$(CLUSTER)" ] || { echo "aborted"; exit 1; }
	kind delete cluster --name $(CLUSTER)
	kind create cluster --config kind-config.yaml
	helm repo add argo https://argoproj.github.io/argo-helm
	helm repo update argo
	helm upgrade --install argocd argo/argo-cd -n $(ARGOCD_NS) --create-namespace \
	  --set configs.params."server\.insecure"=true --wait --timeout 8m
	@echo "✅ cluster + ArgoCD rebuilt. Now run: make image-load && make bootstrap"

##@ Cleanup
.PHONY: destroy
destroy: ## Delete the root app; ArgoCD prunes every child it created
	kubectl delete -f gitops/bootstrap/root-app.yaml --ignore-not-found
	@echo "root app deleted. CRDs are kept (prune: false on kserve-crd)."
