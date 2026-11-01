#!/usr/bin/env bash
# Create an invited LibreChat user inside the running pod. Self-registration is off, so this is the only way in.
# Runs interactively: you type the password at the prompt. It is never passed as an argument or logged.
#   ./scripts/create-chat-user.sh you@example.com "Display Name" username
set -euo pipefail
[[ $# -eq 3 ]] || { echo "usage: $0 <email> <display name> <username>" >&2; exit 1; }
kubectl -n chat exec -it deploy/librechat -- npm run create-user -- "$1" "$2" "$3"
