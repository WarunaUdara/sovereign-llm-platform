#!/usr/bin/env bash
# Drill D1: kill the model pod. Hypothesis (write before running): the service is unavailable for roughly
# the model cold start (30 to 60 s), then returns 200 from the chat pod's point of view.
# Measures seconds from the kill to the first successful /health from inside the chat namespace.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$ROOT/evidence/drill-d1-kill-model-$TS.txt"
PROBE='fetch("http://model-endpoint.llm-serving.svc.cluster.local:8080/health").then(r=>console.log(r.status)).catch(e=>console.log("ERR",e.cause?e.cause.code:e.message))'
probe() { kubectl -n chat exec deploy/librechat -- node -e "$PROBE" 2>/dev/null | tail -1; }
{
  echo "# D1 kill model pod  $TS"
  echo "hypothesis: unavailable for about the cold start (30-60 s), then 200 again"
  echo "## before"; kubectl -n llm-serving get pods --no-headers | awk '{print $1,$2,$3}'
  echo "baseline probe: $(probe)"
  T0=$(date +%s)
  kubectl -n llm-serving delete pod -l app.kubernetes.io/name=model-endpoint --wait=false >/dev/null
  echo "t=0 pod deleted"
  DOWN_AT=""; UP_AT=""
  for i in $(seq 1 240); do
    r="$(probe)"; now=$(( $(date +%s) - T0 ))
    [[ -z "$DOWN_AT" && "$r" != "200" ]] && { DOWN_AT=$now; echo "t=${now}s first non-200: ${r:-no response}"; }
    if [[ -n "$DOWN_AT" && "$r" == "200" ]]; then UP_AT=$now; echo "t=${now}s back to 200"; break; fi
    sleep 1
  done
  echo "## result"
  if [[ -n "$UP_AT" ]]; then echo "recovery_seconds=$UP_AT (hypothesis: 30-60)"; else echo "recovery: NOT within 240 s"; fi
  echo "## after"; kubectl -n llm-serving get pods --no-headers | awk '{print $1,$2,$3,$5}'
} | tee "$OUT"
echo "evidence: $OUT"
