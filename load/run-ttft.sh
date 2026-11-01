#!/usr/bin/env bash
# Run the true-TTFT harness inside the serving pod and store the output as evidence.
# The harness is piped over stdin, so nothing is copied into the image and the pod is never modified.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
LEVELS="${TTFT_LEVELS:-1,2,4,6,8}"
SECONDS_PER_LEVEL="${TTFT_SECONDS:-20}"

OUT="$ROOT/evidence/ttft-stream-$TS.txt"
kubectl -n llm-serving exec -i deploy/model-endpoint -- \
  python3 - --levels "$LEVELS" --seconds "$SECONDS_PER_LEVEL" \
  < "$ROOT/load/ttft-stream.py" | tee "$OUT"

echo "evidence: evidence/ttft-stream-$TS.txt"
