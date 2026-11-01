#!/usr/bin/env bash
# Run the in-cluster k6 Job and save its console output and JSON summary as evidence.
# The script copy in deploy/loadtest must match load/k6-streaming.js; this fails if they drift.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
cmp -s "$ROOT/load/k6-streaming.js" "$ROOT/deploy/loadtest/k6-streaming.js" || { echo "script copies differ: sync deploy/loadtest/k6-streaming.js" >&2; exit 1; }
kubectl -n chat delete job k6-streaming --ignore-not-found >/dev/null
kubectl apply -k "$ROOT/deploy/loadtest" >/dev/null
echo "job started at $TS (5 levels: 1, 2, 4, 6, 8 users at 40 s each, about 4 minutes)"
kubectl -n chat wait --for=condition=complete job/k6-streaming --timeout=900s || {
  echo "job did not complete; collecting logs" >&2
  kubectl -n chat logs job/k6-streaming --tail=200 > "$ROOT/evidence/FAILED-load-$TS.txt" 2>&1 || true
  exit 1
}
kubectl -n chat logs job/k6-streaming > "$ROOT/evidence/load-in-cluster-$TS.txt" 2>&1
# Split the JSON summary out of the log into its own evidence file.
sed -n '/=== SUMMARY-JSON ===/,$p' "$ROOT/evidence/load-in-cluster-$TS.txt" | sed '1d' > "$ROOT/evidence/load-in-cluster-$TS.json"
echo "evidence: evidence/load-in-cluster-$TS.txt and .json"
