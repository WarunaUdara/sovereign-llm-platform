#!/usr/bin/env bash
# Create the Grafana admin password locally (gitignored) and push it to the observability namespace.
# The password is never printed. Read it from .secrets/grafana-admin when you sign in.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILE="$ROOT/.secrets/grafana-admin"
mkdir -p "$ROOT/.secrets"; chmod 700 "$ROOT/.secrets"; umask 077
if [[ ! -f "$FILE" ]]; then openssl rand -base64 24 | tr -d '\n' > "$FILE"; echo "generated .secrets/grafana-admin"; fi
chmod 600 "$FILE"
kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n observability create secret generic grafana-admin --from-file=password="$FILE" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "secret grafana-admin applied (value not shown)"
