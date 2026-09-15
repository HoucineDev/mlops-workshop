# mlops-workshop

Serve a real LLM on Kubernetes through **ArgoCD → KServe → LiteLLM**, on a local
`kind` cluster, entirely from Git.

```
   Git (this repo)
        │
        │  ArgoCD syncs, ordered by sync-wave
        ▼
 ┌──────────────────────────────────────────────────────────────────┐
 │ wave 0   cert-manager          webhook certs for KServe          │
 │ wave 1   kserve-crd            InferenceService, ServingRuntime… │
 │ wave 2   kserve                controller, RawDeployment mode    │
 │ wave 3   model-inference       ClusterServingRuntime + ISVC      │
 │ wave 4   litellm-gateway       one OpenAI API for every model    │
 └──────────────────────────────────────────────────────────────────┘

   client ──OpenAI──▶ litellm-gateway.ai-gateway:4000
                            │  openai/smollm2-135m-instruct
                            ▼
                      tiny-llm-predictor.models:80/v1
                            │  (Deployment created by KServe)
                            ▼
                      elhou/tiny-llm-server  →  SmolLM2-135M (GGUF, CPU)
```

## Why it is built this way

Two facts about this environment shaped every other decision.

**1. `kserve/huggingfaceserver` is `linux/amd64` only.**
That is KServe's own OpenAI-compatible runtime, and it is the obvious thing to
reach for. It cannot run on an Apple-Silicon cluster — verified for v0.15.2,
v0.16.0 and v0.20.0. So `images/tiny-llm-server/` builds a **multi-arch
replacement**: llama.cpp's server (which does publish `linux/arm64`, speaks the
OpenAI API natively, and runs a 135M model on CPU) with the GGUF baked in.

Baking the weights into the image also removes KServe's storage-initializer, an
object-storage bucket, and a set of credentials from the picture. The
InferenceService needs no `storageUri` at all.

**2. KServe Serverless needs Knative *and* Istio — roughly 15 extra pods.**
This cluster is one `kind` node with 7.6Gi. So KServe runs in **standard mode**
(`deploymentMode: RawDeployment`): each InferenceService becomes a plain
Deployment + Service + HPA, and the only hard dependency is cert-manager.
`gateway.disableIngressCreation: true` drops the Gateway API/Envoy Gateway
requirement too, because nothing here needs external ingress — LiteLLM is a pod
on the same network.

**LiteLLM speaks OpenAI; KServe's native v1/v2 `:predict` protocol does not.**
That is why the runtime must expose `/v1/chat/completions` rather than
`:predict`, and why LiteLLM addresses it with `model: openai/<name>` plus an
`api_base` pointing at the predictor Service.

## Layout

```
charts/
  model-inference/     generic KServe chart: ClusterServingRuntime + InferenceService
  litellm-gateway/     LiteLLM proxy, model_list templated from the ISVC names
images/
  tiny-llm-server/     multi-arch OpenAI-compatible runtime, model baked in
gitops/
  bootstrap/           AppProject + root app-of-apps — the only kubectl you run
  apps/                one Application per component, ordered by sync-wave
scripts/
  smoke-test.sh        laptop → LiteLLM → KServe → model, end to end
```

## Prerequisites

Already present on this machine: `kubectl`, `helm`, `argocd`, `kind`, `docker`,
`make`. A `kind` cluster named `argocd` with ArgoCD installed.

## Quick start

```bash
# 1. Build and publish the model server (needs: docker login -u elhou)
make push

#    …or skip Docker Hub entirely and load it straight into kind:
make image-load

# 2. Push this repo to GitHub as HoucineDev/mlops-workshop (public)

# 3. Hand the cluster over to ArgoCD — the only imperative step
make bootstrap

# 4. Watch the waves land
make status

# 5. Prove the whole chain works
make test
```

## Reaching the interfaces

There are two ways in, and which one works depends on how the kind cluster was
created. Check with `make ingress-check`.

### Ingress (one front door, hostname-routed)

`ingress-nginx` runs at wave 0 and both UIs have an Ingress:

| Host | Goes to |
| --- | --- |
| `argocd.localtest.me` | the ArgoCD UI |
| `litellm.localtest.me` | the LiteLLM OpenAI API |

`*.localtest.me` resolves to `127.0.0.1` from anywhere, so there is no
`/etc/hosts` entry to add.

**If the cluster maps host ports 80/443** (created from `kind-config.yaml`),
these work directly:

```
http://argocd.localtest.me
http://litellm.localtest.me/v1/models
```

**If it does not** — which is the case for a cluster made with a bare
`kind create cluster` — nothing inside the cluster can bind your Mac's port 80,
because Docker cannot add port mappings to a running container. Until the
cluster is recreated, use one port-forward to the controller and keep the same
hostnames:

```bash
make ingress
# ArgoCD  -> http://argocd.localtest.me:8080
# LiteLLM -> http://litellm.localtest.me:8080
```

`make cluster-recreate` rebuilds the cluster from `kind-config.yaml` with 80/443
mapped. It is destructive — it deletes the cluster and ArgoCD with it — but
every workload comes back from Git with `make bootstrap`.

### Port-forward (no ingress involved)

```bash
make ui                 # ArgoCD  -> http://localhost:8080
make argocd-password    # the admin password
make gateway            # LiteLLM -> http://localhost:4000
```

Note the ArgoCD UI is **http**, not https. This install runs
`server.insecure=true`, so `argocd-server` serves plain HTTP; sending it a TLS
handshake gets the connection reset.

### The LiteLLM Admin UI

```
http://litellm.localtest.me:8080/ui
```

Username `admin`, password is the **master key**. The UI needs the bundled
PostgreSQL (`postgresql.enabled`, on by default); with it disabled every login
fails with *"Authentication Error, Not connected to DB!"* while the API keeps
working normally.

### Calling LiteLLM

```bash
KEY=$(kubectl get secret -n ai-gateway litellm-gateway-masterkey \
        -o jsonpath='{.data.masterkey}' | base64 -d)

curl http://litellm.localtest.me:8080/v1/chat/completions \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"tiny-llm","messages":[{"role":"user","content":"Hello"}]}'
```

Any OpenAI client works against it — point `base_url` at the same address.

## Operating it

| Command | What it does |
| --- | --- |
| `make status` | Sync/health per Application, plus the InferenceService |
| `make sync` | Force a hard refresh of the root app |
| `make ui` | Port-forward the ArgoCD UI to <http://localhost:8080> (this ArgoCD runs `server.insecure=true`, so it is HTTP, not HTTPS) |
| `make gateway` | Port-forward LiteLLM to <http://localhost:4000> |
| `make test-predictor` | Hit the KServe predictor directly, bypassing LiteLLM |
| `make publish` | Package both charts and push them to Docker Hub as OCI artifacts |
| `make destroy` | Delete the root app; ArgoCD prunes every child |

## Chart delivery: Git for sync, Docker Hub for releases

The Applications in `gitops/apps/` read charts from **this repo's path**, so a
template change is live as soon as it is pushed — no package/push/version-bump
cycle in the edit loop.

`make publish` packages the *same* charts and pushes them to
`oci://registry-1.docker.io/elhou` for versioned releases. To make ArgoCD
consume those instead, swap the source block in `30-model-inference.yaml` for
the commented-out OCI form beneath it.

## Adding a second model

1. Copy `charts/model-inference/values.yaml` to a new values file, change
   `inferenceService.name` and `servingRuntime.modelAlias`.
2. Add an Application in `gitops/apps/` at wave 3 pointing at it.
3. Append an entry to `kserve.inferenceServices` in
   `charts/litellm-gateway/values.yaml` — LiteLLM's `model_list` is templated
   from that list, so the routing follows automatically.

Nothing is applied by hand. Push, and ArgoCD does the rest.

## Things worth knowing

- **Never `kubectl apply` an Application.** Everything below the root app is
  owned by Git. Applying by hand is how a GitOps setup silently drifts.
- **`kserve-crd` has `prune: false`.** Pruning CRDs deletes every
  InferenceService in the cluster with them.
- **CRD Applications use `ServerSideApply=true` and `Replace=true`.** KServe's
  OpenAPI schemas exceed the 262144-byte annotation limit that client-side
  apply relies on.
- **The LiteLLM master key is in Git**, because this is a workshop. For anything
  real, set `masterKey.create: false` and point `masterKey.existingSecret` at a
  Secret managed by External Secrets or Sealed Secrets.
- **LiteLLM runs without a database.** That means no virtual keys, budgets or
  spend tracking — and no PostgreSQL. Use the upstream
  `oci://ghcr.io/berriai/litellm-helm` chart when you need them.
