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

**Revised 2026-09-15 — PostgreSQL added back.** The original write-up said
dropping the database costs "virtual keys, budgets and spend tracking." That
undersold it: it also disables the **Admin UI completely**. Every login at
`/ui` fails with

```
Authentication Error, Not connected to DB!
```

because the UI has no user store to authenticate against. The API is unaffected,
but anyone who opens the UI hits a wall with no obvious cause.

The chart now ships an optional `postgresql` block (`enabled: true` by default):
a single-replica StatefulSet with a PVC, and `DATABASE_URL` wired into the
proxy, which runs its Prisma migration at startup. Costs ~256Mi. Set
`postgresql.enabled: false` to go back to API-only — a legitimate choice if you
never need the UI, as long as you know the UI goes with it.

A StatefulSet rather than a Deployment because the PVC belongs to one database
identity; a Deployment sharing a PVC could run two postgres processes against
the same data directory during a rolling update.

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

---

## 10. `deploymentMode: Standard`, not `RawDeployment`

**Symptom.** `model-inference` sat `OutOfSync` forever while reporting `Healthy`,
and the root app stalled at wave 3 with *"waiting for healthy state of
Application/model-inference"* — so wave 4 (`litellm-gateway`) was never created.

**Cause.** KServe v0.20 renamed this deployment mode from `RawDeployment` to
`Standard`. The old spelling still *works*, but the mutating webhook silently
rewrites the annotation:

```
<     serving.kserve.io/deploymentMode: Standard      # live, after the webhook
>     serving.kserve.io/deploymentMode: RawDeployment # Git
```

ArgoCD compared the two and reported a diff it could never close — each sync
wrote `RawDeployment`, each admission rewrote it to `Standard`.

This is worse than a cosmetic diff because of the Application health check in
`argocd-cm`, which reports `Healthy` only when a child app is **Healthy AND
Synced**. One permanently-OutOfSync child therefore blocks every later wave.

**Fix.** Write `Standard` in the chart. Confirmed against the live webhook:

```bash
kubectl apply --server-side --dry-run=server -f isvc.yaml \
  -o jsonpath='{.metadata.annotations.serving\.kserve\.io/deploymentMode}'
# -> Standard
```

**The general lesson.** When a GitOps app will not converge, get the real diff
before theorising — `argocd app diff <app> --core` reads it straight from the
Kubernetes API and needs no port-forward or login:

```bash
kubectl config view --raw > /tmp/kc.yaml
KUBECONFIG=/tmp/kc.yaml kubectl config set-context --current --namespace=argocd
KUBECONFIG=/tmp/kc.yaml argocd app diff model-inference --core
```

An `ignoreDifferences` block aimed at the wrong fields was tried first and
changed nothing, because it papered over a symptom that was never the cause.

---

## 11. `make ui` uses HTTP, not HTTPS

This ArgoCD runs with `server.insecure = true` in `argocd-cmd-params-cm`, so
`argocd-server` serves **plain HTTP**. Verified from inside the cluster:

```
http  -> argocd-server.argocd.svc:80    200
https -> argocd-server.argocd.svc:443   000  (connection reset)
http  -> argocd-server.argocd.svc:443   200
```

Both Service ports point at the same plain-HTTP container port 8080; the `:443`
name is not a TLS listener. Forwarding `:443` and opening `https://` sends a TLS
handshake to an HTTP listener, and the server resets the connection.

---

## 12. Ingress on kind: two cluster shapes

**The constraint.** A cluster created with a bare `kind create cluster` maps only
the API server to the host:

```
$ docker port argocd-control-plane
6443/tcp -> 127.0.0.1:53796
```

With no host mapping for 80/443, nothing inside the cluster can answer on your
Mac's port 80, whatever the ingress controller is told. Docker cannot add port
mappings to a running container, so the only real fix is recreating the cluster
from `kind-config.yaml`.

**The design.** One ingress-nginx config that works either way: `hostPort`
enabled (so a cluster built from `kind-config.yaml` serves directly on :80) and
`make ingress` port-forwarding the controller otherwise. The same hostnames —
`argocd.localtest.me`, `litellm.localtest.me` — work in both, just on a
different port.

Two things deliberately *not* done:

- **No `nodeSelector: ingress-ready=true`.** That label exists only on a cluster
  built from `kind-config.yaml`; requiring it strands the controller in Pending
  on the current one.
- **Service type NodePort, not the chart default LoadBalancer.** kind has no
  cloud provider, so a LoadBalancer Service stays `<pending>` and the
  Application never reports Healthy.

### 12a. `publishService` vs. Ingress ADDRESS

ingress-nginx defaults to copying its Service's `loadBalancer` status onto every
Ingress. A NodePort Service has none, so `kubectl get ingress` showed an empty
ADDRESS — and **ArgoCD reports an address-less Ingress as Progressing forever**.
`publishService.enabled: false` + `reportNodeInternalIp: true` publishes node
IPs instead, and the Ingresses go Healthy.

### 12b. `maxSurge: 0`, and why `Recreate` does not work

`hostPort` is exclusive per node, and this cluster has one node. The chart's
default `maxSurge: 25%` creates the replacement pod before retiring the old one,
so it waits forever for a port the old pod will not release:

```
0/1 nodes are available: 1 node(s) didn't have free ports for the requested pod ports
```

`strategy.type: Recreate` is the obvious fix and is **rejected outright**:

```
Deployment.apps "ingress-nginx-controller" is invalid:
spec.strategy.rollingUpdate: Forbidden: may not be specified when strategy `type` is 'Recreate'
```

Server-side apply keeps the defaulted `rollingUpdate` block, which
`kube-controller-manager` owns and the applier cannot remove, and `Recreate`
alongside it is invalid. `maxSurge: 0` requires removing no field, so it applies.

### 12c. Terminating a stuck retry

A failed sync retries with the **manifests captured when the operation started**.
After fixing the values, ArgoCD still replayed the old `Recreate` manifest and
kept failing — `argocd app manifests --core` showed the *correct* new render
while the retry kept erroring on the old one. Deleting `/operation` does not
help: the retry re-arms it. The way out is to terminate the operation:

```bash
argocd app terminate-op <app> --core
argocd app sync <app> --core
```

**Recurring theme.** Four separate times in this build, one resource that could
never reach Healthy silently held an entire sync wave — the `deploymentMode`
rename, the address-less Ingress, the hostPort rollout, and the stale retry. The
Application health check requires Synced **and** Healthy, so "Progressing
forever" is indistinguishable from "still working" until you read the diff.

---

## 13. Adding PostgreSQL: four bugs worth recording

Enabling the Admin UI meant adding a database, and the database surfaced four
distinct failures. Each is a general Kubernetes trap, not a LiteLLM quirk.

### 13a. A sync-wave applies per resource, not per file

The postgres StatefulSet was annotated `sync-wave: "-1"` so it starts before the
proxy. Its Secret and Service, in the same template file, were left at the
default wave 0 — so ArgoCD created the StatefulSet *first*:

```
CreateContainerConfigError: secret "litellm-gateway-postgresql" not found
```

Everything a wave -1 workload needs must also be wave -1.

### 13b. The container OOMKills before it can log anything

With `DATABASE_URL` set, the proxy generates a Prisma client and runs a schema
migration before serving. That startup peak blew the 1Gi limit that was fine for
config-only mode. The pod produced **no logs at all** and simply restarted; the
cause was only visible in `lastState`:

```
{"terminated":{"exitCode":137,"reason":"OOMKilled"}}
```

An empty log plus a restart loop means read `lastState` before anything else.
Now 768Mi request / 2Gi limit.

### 13c. Two proxy pods will not fit during a rollout

The default `maxSurge: 25%` runs two LiteLLM pods at once. With postgres now
also resident, that starved the node badly enough that the kubelet and API server
degraded — `kubectl` began failing with `net/http: TLS handshake timeout`.
`maxSurge: 0` retires the old pod first. Same fix as ingress-nginx, different
cause: there an exclusive hostPort, here memory.

### 13d. A `component` label does not separate workloads

The postgres pods were given `litellm-gateway.selectorLabels` plus
`app.kubernetes.io/component: postgresql`. But the proxy's Service and Deployment
select on **name + instance only**, so those two labels alone matched the
database pod. The proxy Service ended up with two EndpointSlices:

```
litellm-gateway-272vw   [10.244.0.40]   <- the proxy
litellm-gateway-gncst   [10.244.0.37]   <- postgres
```

Roughly half of every API request was load-balanced onto a port speaking the
postgres wire protocol — `/ui` and `/key/generate` returned 503 and 000 while
`kubectl get pods` showed 1/1 Ready and healthy. Adding a label a selector does
not look at changes nothing; the fix is a distinct `app.kubernetes.io/name`.

Note both selectors are **immutable**, so the StatefulSet had to be recreated.
`kubectl delete statefulset --cascade=orphan` keeps the PVC and its data.

### Verified working

| Check | Result |
| --- | --- |
| `litellm.localtest.me/ui/` | HTTP 200 |
| Virtual key created and persisted | `sk-YDBX…` |
| Chat completion authenticated by that virtual key | ✅ |
| `argocd.localtest.me` | HTTP 200 |
