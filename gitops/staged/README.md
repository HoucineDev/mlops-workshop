# Staged applications — not yet deployed

Applications here are **not** picked up by the root app. `mlops-root` watches
`gitops/apps/` only.

They live outside that directory on purpose. An Application inside `gitops/apps/`
is created by the root app immediately, and an Application that is created but
not synced reports OutOfSync — which, because the Application health check in
`argocd-cm` requires Synced **and** Healthy, stalls the root app's wave ordering
and blocks every later wave. That failure mode cost several hours; see
`docs/DECISIONS.md` §10 and §15.

## Deploying these

Once the cluster has headroom (Docker Desktop raised to 12-16 GB):

```bash
git mv gitops/staged/0*-*.yaml gitops/staged/60-agent-router.yaml gitops/apps/
git commit -m "Deploy Envoy AI Gateway"
git push
make status
```

Order is handled by the sync-wave annotations already on each file.
