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
cd ~/my-saas/mlops-workshop
make agent-router-deploy
```

Or by hand — note this is ONE command. Pasting it across several lines makes
`git mv` treat the last filename as the destination and fail with
*"destination ... is not a directory"*:

```bash
git mv gitops/staged/0*.yaml gitops/staged/60-agent-router.yaml gitops/apps/ && \
  git commit -m "Deploy Envoy AI Gateway" && git push
```

## Before deploying

Check there is room. This adds roughly 700Mi across Envoy Gateway, the AI
Gateway controller and one Envoy data-plane pod:

```bash
make headroom
```

Order is handled by the sync-wave annotations already on each file.
