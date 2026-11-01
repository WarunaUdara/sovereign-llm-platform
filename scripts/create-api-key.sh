#!/usr/bin/env bash
# Create (or rotate) the model's API keys and push them to the cluster.
#   line 1 of .secrets/api-keys: inference key (used by the chat UI, via llm-serving's key file)
#   line 2 of .secrets/api-keys: metrics key (used only by the Prometheus scraper)
# Both keys are accepted by llama-server. Keys are never printed or committed.
#   ./scripts/create-api-key.sh            create what is missing
#   ./scripts/create-api-key.sh --rotate   replace both keys
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRET_DIR="$ROOT/.secrets"
KEY_FILE="$SECRET_DIR/api-keys"
NAMESPACE="llm-serving"
ROTATE=0
[[ "${1:-}" == "--rotate" ]] && ROTATE=1

mkdir -p "$SECRET_DIR"
chmod 700 "$SECRET_DIR"
umask 077

new_key() { printf 'sk-local-%s' "$(openssl rand -hex 32)"; }

if [[ ! -f "$KEY_FILE" || $ROTATE -eq 1 ]]; then
  { new_key; echo; new_key; echo; } > "$KEY_FILE"
  echo "API keys written to .secrets/api-keys (mode 600, inference + metrics)"
elif [[ $(grep -c . "$KEY_FILE") -lt 2 ]]; then
  # Upgrade a file created before the metrics key existed; the inference key is kept as-is.
  echo "$(new_key)" >> "$KEY_FILE"
  echo "metrics key added to .secrets/api-keys"
else
  echo "API keys already exist at .secrets/api-keys (use --rotate to replace them)"
fi
chmod 600 "$KEY_FILE"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$NAMESPACE" create secret generic llm-api-keys \
  --from-file=api-keys="$KEY_FILE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# Scraper credential as its own Secret, so PodMonitoring never reads the inference key.
sed -n '2p' "$KEY_FILE" | tr -d '\n' > "$SECRET_DIR/metrics-token"
chmod 600 "$SECRET_DIR/metrics-token"
kubectl -n "$NAMESPACE" create secret generic llm-metrics-token \
  --from-file=token="$SECRET_DIR/metrics-token" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "secrets llm-api-keys and llm-metrics-token applied to namespace $NAMESPACE"
