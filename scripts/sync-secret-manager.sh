#!/usr/bin/env bash
# Push the locally generated secret values into Google Secret Manager as new versions.
# Values travel on stdin (never argv, never the environment) and are never printed. OpenTofu creates the
# containers and grants; this script only adds versions. Re-run after ./scripts/create-*.sh --rotate.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CLOUDSDK_CORE_PROJECT="${PROJECT_ID:-llm-k8s-experimental}"

push() { # push <secret-name> <local-file>
  [[ -f "$2" ]] || { echo "missing local file for $1: $2" >&2; exit 1; }
  gcloud secrets versions add "$1" --data-file=- < "$2" >/dev/null
  echo "added version: $1"
}

push llm-api-keys          "$ROOT/.secrets/api-keys"
# Chat gets only the inference key (line 1), never the metrics key.
sed -n '1p' "$ROOT/.secrets/api-keys" | tr -d '\n' | gcloud secrets versions add llm-inference-key --data-file=- >/dev/null
echo "added version: llm-inference-key"
# Metrics key is line 2 of the key file. Read it through a pipe, not a temp file, so it never sits on disk.
sed -n '2p' "$ROOT/.secrets/api-keys" | tr -d '\n' | gcloud secrets versions add llm-metrics-token --data-file=- >/dev/null
echo "added version: llm-metrics-token"
push librechat-creds-key   "$ROOT/.secrets/chat/creds_key"
push librechat-creds-iv    "$ROOT/.secrets/chat/creds_iv"
push librechat-jwt-secret  "$ROOT/.secrets/chat/jwt_secret"
push librechat-jwt-refresh "$ROOT/.secrets/chat/jwt_refresh_secret"
