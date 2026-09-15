#!/usr/bin/env bash
# End-to-end check: laptop -> LiteLLM -> KServe predictor -> SmolLM2.
#
# Opens its own port-forward and tears it down on exit, so it needs no
# already-running `make gateway`.
set -euo pipefail

GATEWAY_NS="${GATEWAY_NS:-ai-gateway}"
MODEL_NS="${MODEL_NS:-models}"
ISVC="${ISVC:-tiny-llm}"
PORT="${LITELLM_PORT:-4000}"
MODEL_ALIAS="${MODEL_ALIAS:-tiny-llm}"

# Read the master key from the cluster rather than hardcoding it, so this keeps
# working after you rotate it.
MASTER_KEY="$(kubectl get secret -n "$GATEWAY_NS" litellm-gateway-masterkey \
  -o jsonpath='{.data.masterkey}' 2>/dev/null | base64 -d || echo "")"
if [[ -z "$MASTER_KEY" ]]; then
  echo "could not read the LiteLLM master key from secret litellm-gateway-masterkey in $GATEWAY_NS" >&2
  exit 1
fi

echo "==> 1/3  KServe InferenceService"
kubectl get inferenceservice "$ISVC" -n "$MODEL_NS"

echo
echo "==> 2/3  predictor answers /v1/models directly"
kubectl run "smoke-predictor-$RANDOM" --rm -i --restart=Never -n "$MODEL_NS" \
  --image=curlimages/curl:8.11.1 --quiet -- \
  curl -sS --max-time 20 "http://${ISVC}-predictor.${MODEL_NS}.svc.cluster.local/v1/models"

echo
echo "==> 3/3  chat completion through LiteLLM"
kubectl port-forward -n "$GATEWAY_NS" "svc/litellm-gateway" "${PORT}:${PORT}" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT

for i in $(seq 1 30); do
  curl -sf "http://localhost:${PORT}/health/liveliness" >/dev/null 2>&1 && break
  sleep 1
  [[ $i -eq 30 ]] && { echo "port-forward never became reachable" >&2; exit 1; }
done

curl -sS --max-time 120 "http://localhost:${PORT}/v1/chat/completions" \
  -H "Authorization: Bearer ${MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL_ALIAS}\",\"messages\":[{\"role\":\"user\",\"content\":\"In one short sentence: what is Kubernetes?\"}],\"max_tokens\":64}" \
  | python3 -m json.tool

echo
echo "✅ ArgoCD -> KServe -> LiteLLM chain is working."
