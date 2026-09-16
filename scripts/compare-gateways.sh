#!/usr/bin/env bash
# Same prompt, same model, same KServe backend — through LiteLLM and through
# Agent Router. This is the measurement the study's POC asks for: both gateways
# front identical upstreams, so any difference is the gateway's.
#
# Reports latency for each. Note this measures gateway + inference together; on
# CPU inference dominates, so treat it as a smoke test rather than the p99
# benchmark in the study's exit criteria.
set -euo pipefail

MODEL="${MODEL:-qwen3}"
PROMPT="${PROMPT:-In one short sentence: what is Kubernetes?}"
GATEWAY_NS="${GATEWAY_NS:-ai-gateway}"

MASTER_KEY="$(kubectl get secret -n "$GATEWAY_NS" litellm-gateway-masterkey \
  -o jsonpath='{.data.masterkey}' 2>/dev/null | base64 -d || echo "")"
[[ -z "$MASTER_KEY" ]] && { echo "could not read the LiteLLM master key" >&2; exit 1; }

# Envoy Gateway creates the proxy Service in its own namespace with a hashed
# name, so discover it by the owning-gateway label rather than guessing.
ENVOY_NS="${ENVOY_NS:-envoy-gateway-system}"
ENVOY_SVC="$(kubectl get svc -n "$ENVOY_NS" \
  -l gateway.envoyproxy.io/owning-gateway-name=agent-router \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")"
if [[ -z "$ENVOY_SVC" ]]; then
  echo "Agent Router is not deployed yet (no Envoy Service for the gateway)." >&2
  echo "Deploy it with: make agent-router-deploy" >&2
  exit 1
fi

BODY=$(printf '{"model":"%s","messages":[{"role":"user","content":"%s"}],"max_tokens":60}' "$MODEL" "$PROMPT")

call() { # name port extra-header
  local name=$1 port=$2 auth=${3:-}
  local t0 t1
  t0=$(python3 -c 'import time;print(time.time())')
  local out
  out=$(curl -sS --max-time 180 "http://127.0.0.1:${port}/v1/chat/completions" \
        ${auth:+-H "$auth"} -H 'Content-Type: application/json' -d "$BODY" || echo '{}')
  t1=$(python3 -c 'import time;print(time.time())')
  python3 - "$name" "$t0" "$t1" <<PY
import json,sys
name,t0,t1=sys.argv[1],float(sys.argv[2]),float(sys.argv[3])
raw='''$out'''
try:
    d=json.loads(raw)
    c=d['choices'][0]['message'].get('content','').strip().replace('\n',' ')
    print(f"  {name:<14} {t1-t0:6.2f}s  {c[:90]}")
except Exception:
    print(f"  {name:<14} {t1-t0:6.2f}s  ERROR: {raw[:120]}")
PY
}

kubectl port-forward -n "$GATEWAY_NS" svc/litellm-gateway 14000:4000 >/dev/null 2>&1 &
PF1=$!
kubectl port-forward -n "$ENVOY_NS" "svc/${ENVOY_SVC}" 14001:80 >/dev/null 2>&1 &
PF2=$!
trap 'kill "$PF1" "$PF2" 2>/dev/null || true' EXIT

for i in $(seq 1 30); do
  curl -sf http://127.0.0.1:14000/health/liveliness >/dev/null 2>&1 && break
  sleep 1
done
sleep 2

echo "model=$MODEL  prompt=\"$PROMPT\""
echo
# LiteLLM authenticates with the master key. Agent Router delegates client auth
# to Envoy Gateway's SecurityPolicy, which is not configured here, so it is open.
call "LiteLLM"      14000 "Authorization: Bearer ${MASTER_KEY}"
call "Agent Router" 14001
