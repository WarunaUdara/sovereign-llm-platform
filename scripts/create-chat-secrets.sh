#!/usr/bin/env bash
# Create LibreChat's secrets locally (gitignored) and push them to the chat namespace.
# The model key is copied from .secrets/api-keys because a Secret cannot be read across namespaces.
#   ./scripts/create-chat-secrets.sh            create what is missing
#   ./scripts/create-chat-secrets.sh --rotate   replace all chat secrets (users must sign in again)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="$ROOT/.secrets/chat"
NS="chat"
ROTATE=0
[[ "${1:-}" == "--rotate" ]] && ROTATE=1

[[ -f "$ROOT/.secrets/api-keys" ]] || { echo "model key missing: run scripts/create-api-key.sh first" >&2; exit 1; }
mkdir -p "$DIR"; chmod 700 "$DIR"
umask 077

gen() { # gen <file> <command that prints a secret>
  if [[ ! -f "$DIR/$1" || $ROTATE -eq 1 ]]; then eval "$2" > "$DIR/$1"; fi
}
# CREDS_KEY is 32 bytes (exactly 64 hex chars); CREDS_IV is 16 bytes (exactly 32 hex chars).
# The tr strips the trailing newline: LibreChat refuses to start on a 65-character key.
gen creds_key 'openssl rand -hex 32 | tr -d "\n"'
gen creds_iv  'openssl rand -hex 16 | tr -d "\n"'
gen jwt_secret 'openssl rand -base64 48 | tr -d "\n"'
gen jwt_refresh_secret 'openssl rand -base64 48 | tr -d "\n"'
# First line only: line 2 is the metrics key and must not reach the chat UI.
sed -n '1p' "$ROOT/.secrets/api-keys" | tr -d '\n' > "$DIR/llm_api_key"
chmod 600 "$DIR"/*

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$NS" create secret generic librechat-secrets \
  --from-file=CREDS_KEY="$DIR/creds_key" \
  --from-file=CREDS_IV="$DIR/creds_iv" \
  --from-file=JWT_SECRET="$DIR/jwt_secret" \
  --from-file=JWT_REFRESH_SECRET="$DIR/jwt_refresh_secret" \
  --from-file=LLM_API_KEY="$DIR/llm_api_key" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "secret librechat-secrets applied to namespace $NS (values never printed)"
