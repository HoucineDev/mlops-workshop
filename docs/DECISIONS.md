# Design decisions

Each entry records a choice that was not obvious, the constraint that forced it,
and what it would take to reverse.

---

## 1. Build our own model runtime instead of using `kserve/huggingfaceserver`

**Constraint.** `kserve/huggingfaceserver` publishes `linux/amd64` only —
confirmed for v0.15.2, v0.16.0 and v0.20.0:

```bash
docker manifest inspect kserve/huggingfaceserver:v0.20.0   # linux/amd64
docker manifest inspect kserve/kserve-controller:v0.20.0   # amd64, arm, arm64, ppc64le, s390x
```

The KServe *control plane* is multi-arch; only the HuggingFace *runtime* is not.
On an Apple-Silicon cluster that runtime could only run under emulation.

**Decision.** `images/tiny-llm-server/` wraps `ghcr.io/ggml-org/llama.cpp:server`
(multi-arch, OpenAI-native, CPU-friendly) and bakes a GGUF into the image.

**Reversing it.** On an amd64 cluster, point `servingRuntime.image` at
`kserve/huggingfaceserver`, set `predictor.storageUri` to the model location,
and change `modelFormat` to `huggingface`. The chart needs no other change.

---

## 2. RawDeployment, not Serverless

**Constraint.** KServe Serverless requires Knative Serving *and* Istio. On a
single `kind` node with 7.6Gi and 8 CPUs, that is most of the budget spent
before the first model pod is scheduled.

**Decision.** `deploymentMode: RawDeployment`. Each InferenceService becomes a
Deployment + Service + HPA. cert-manager is the only hard dependency.

**What is given up.** Scale-to-zero, traffic splitting between revisions, and
request-driven autoscaling. None is used here. HPA still gives CPU-based scaling.

**Reversing it.** Install Knative + Istio, then drop the
`serving.kserve.io/deploymentMode` annotation from the InferenceService.

---

## 3. `gateway.disableIngressCreation: true`

**Constraint.** In RawDeployment, KServe wants Gateway API plus an
implementation (Envoy Gateway) to publish each InferenceService externally.

**Decision.** Disabled. LiteLLM is a pod on the same network and reaches the
predictor through its ClusterIP Service. Nothing needs external ingress.

**Reversing it.** Install Gateway API CRDs + Envoy Gateway, set
`ingressGateway.enableGatewayApi: true`, and flip this back to `false`.

---

## 4. Weights baked into the image, no `storageUri`

**Constraint.** `storageUri` pulls KServe's storage-initializer in as an init
container, which needs a bucket and credentials.

**Decision.** The GGUF is a build-time `COPY`, pinned by sha256 from
HuggingFace's `x-linked-etag` header. The InferenceService has no `storageUri`,
so no init container is injected.

**Trade-off.** A new model version means a new image tag, so weights and runtime
version together. At 105MB that is cheap; at 7GB it would not be — that is the
point at which `storageUri` starts to earn its complexity.

---

## 5. A hand-written LiteLLM chart, not the upstream one

**Constraint.** `oci://ghcr.io/berriai/litellm-helm` defaults to
`db.deployStandalone: true` plus a schema-migration Job. Those exist for virtual
keys and spend tracking, neither of which this workshop uses, and they cost
roughly 300Mi on a node that does not have it spare.

**Decision.** A ~120-line chart: Deployment, Service, ConfigMap, Secret,
ServiceAccount. It also templates `model_list` from
`kserve.inferenceServices`, so predictor URLs stay correct when an
InferenceService is renamed — something a values-only wrapper cannot do.

**Reversing it.** For virtual keys, budgets or spend logging, switch the
Application to the upstream chart and set `db.deployStandalone: true`.

---

## 6. Charts from Git, published to Docker Hub separately

**Decision.** ArgoCD reads charts from this repo's path; `make publish` pushes
the same charts to `oci://registry-1.docker.io/elhou`.

**Why not OCI-only.** Every template edit would need package + push + version
bump before ArgoCD could see it. Docker Hub also rate-limits anonymous pulls,
which ArgoCD's repo-server would hit on every refresh.

**Why not Git-only.** Published charts give consumers outside this cluster an
immutable, versioned artifact.

---

## 7. LiteLLM runs as root

**Constraint.** The upstream image declares `USER root` and its entrypoint
(`docker/prod_entrypoint.sh`) writes into `/app` at startup. Forcing
`runAsNonRoot: true` makes the pod CrashLoop.

**Decision.** Drop all capabilities and `allowPrivilegeEscalation: false`, but
leave the uid alone.

**If your cluster enforces restricted PodSecurity**, you need a rebuilt image,
not a values override. The model server, by contrast, *is* verified to run as
uid 65532 with a read-only root filesystem.

---

## 8. `prune: false` on `kserve-crd`

Pruning a CRD deletes every custom resource of that kind, cluster-wide. An
accidental prune of `inferenceservices.serving.kserve.io` would silently delete
every model in the cluster. CRDs are removed deliberately, by hand, or not
at all.

---

## 9. Verified results (2026-09-15, kind-argocd, arm64, 8 CPU / 7.6Gi)

| Check | Result |
| --- | --- |
| `tiny-llm-server` starts as uid 65532, read-only rootfs | healthy in **2s** |
| InferenceService `tiny-llm` | **READY in 12s** |
| Predictor `GET /v1/models` | returns `smollm2-135m-instruct` |
| LiteLLM proxy init | `Proxy initialized with Config, Set models: tiny-llm` |
| End-to-end chat completion | **164 tok/s** generation on CPU |
| Whole stack node footprint | **23% CPU / 24% memory** requests |

The InferenceService reports a URL of `http://tiny-llm-models.example.com`. That
is KServe's default `ingressDomain` being templated into the status field, and
it is cosmetic here — `disableIngressCreation: true` means no Ingress or
HTTPRoute is created and nothing resolves that name. The address that matters is
the predictor Service, `tiny-llm-predictor.models.svc.cluster.local`.
