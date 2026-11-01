#!/usr/bin/env bash
# End-to-end checks against the model endpoint through a port-forward (GKE or any cluster in context).
# Every check prints its actual result. Failures are counted and reported, never hidden.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS="llm-serving"
SVC="svc/model-endpoint"
PORT="${SMOKE_PORT:-18080}"
BASE="http://127.0.0.1:${PORT}"
KEY="$(head -n1 "$ROOT/.secrets/api-keys")"
MODEL_ALIAS="qwen2.5-0.5b-instruct"
SENTINEL="SENTINEL-$(openssl rand -hex 6)"
PASS=0; FAILN=0

check() { # check <name> <condition exit code>
  if [[ "$2" == 0 ]]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1"; FAILN=$((FAILN+1)); fi
}

kubectl -n "$NS" port-forward "$SVC" "${PORT}:8080" >/tmp/llm-pf.log 2>&1 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null' EXIT

for _ in $(seq 1 30); do
  curl -fsS "$BASE/health" >/dev/null 2>&1 && break
  sleep 1
done

echo "== reachability and auth"
curl -fsS "$BASE/health" >/dev/null 2>&1; check "GET /health answers" $?

CODE=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/v1/models")
[[ "$CODE" == 401 ]]; check "no key -> 401 (got $CODE)" $?

CODE=$(curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer sk-wrong' "$BASE/v1/models")
[[ "$CODE" == 401 ]]; check "wrong key -> 401 (got $CODE)" $?

echo "== OpenAI-compatible API"
curl -fsS -H "Authorization: Bearer $KEY" "$BASE/v1/models" | grep -q "$MODEL_ALIAS"; check "GET /v1/models lists $MODEL_ALIAS" $?

RESP=$(curl -fsS -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' "$BASE/v1/chat/completions" \
  -d "{\"model\":\"$MODEL_ALIAS\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the word: pong\"}],\"max_tokens\":16,\"temperature\":0}" 2>/dev/null)
echo "$RESP" | grep -q '"choices"'; check "non-stream chat completion returns choices" $?
echo "    sample: $(echo "$RESP" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["choices"][0]["message"]["content"][:80])' 2>/dev/null)"

STREAM=$(curl -fsS -N -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' "$BASE/v1/chat/completions" \
  -d "{\"model\":\"$MODEL_ALIAS\",\"messages\":[{\"role\":\"user\",\"content\":\"Count to three.\"}],\"max_tokens\":32,\"stream\":true}" 2>/dev/null)
echo "$STREAM" | grep -q '^data: ' && echo "$STREAM" | grep -q '\[DONE\]'; check "streamed completion is SSE and ends with [DONE]" $?

echo "== Anthropic-compatible API (recorded, not assumed)"
CODE=$(curl -s -o /tmp/llm-anth.json -w '%{http_code}' -H "x-api-key: $KEY" -H 'anthropic-version: 2023-06-01' \
  -H 'Content-Type: application/json' "$BASE/v1/messages" \
  -d "{\"model\":\"$MODEL_ALIAS\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"Say hi\"}]}")
if [[ "$CODE" == 200 ]]; then check "POST /v1/messages (Anthropic shape) returns 200" 0
else check "POST /v1/messages returns 200 (got $CODE). This build may not implement it; record in ADR 0003" 1; fi

echo "== limits"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  "$BASE/v1/chat/completions" -d "{\"model\":\"$MODEL_ALIAS\",\"messages\":[{\"role\":\"user\",\"content\":\"$(head -c 40000 /dev/zero | tr '\0' 'a')\"}],\"max_tokens\":8}")
[[ "$CODE" =~ ^4 ]]; check "oversized prompt rejected with 4xx (got $CODE)" $?

echo "== privacy: prompt body must not reach logs"
curl -s -o /dev/null -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' "$BASE/v1/chat/completions" \
  -d "{\"model\":\"$MODEL_ALIAS\",\"messages\":[{\"role\":\"user\",\"content\":\"$SENTINEL\"}],\"max_tokens\":4}"
sleep 2
if kubectl -n "$NS" logs deploy/model-endpoint --tail=500 2>/dev/null | grep -q "$SENTINEL"; then
  check "sentinel prompt absent from pod logs (FOUND in logs)" 1
else
  check "sentinel prompt absent from pod logs" 0
fi

echo "== network isolation (GKE: nodes have no internet route; the test target is a Google API the nodes CAN reach)"
# A success here would mean the policy is not enforced. The control comparison (no policy, same target)
# is recorded in evidence/ so this check is not passing merely because the network is down.
if kubectl -n "$NS" exec deploy/model-endpoint -- curl -s -m 8 -o /dev/null https://artifactregistry.googleapis.com 2>/dev/null; then
  check "model pod egress to Google API is BLOCKED (egress succeeded: policy not enforced)" 1
else
  check "model pod egress to Google API is blocked by NetworkPolicy" 0
fi

echo
echo "result: $PASS passed, $FAILN failed"
(( FAILN == 0 ))
