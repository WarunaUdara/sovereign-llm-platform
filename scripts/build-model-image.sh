#!/usr/bin/env bash
# Build the model-serving image for linux/amd64 (GKE nodes), push it to Artifact Registry, and
# record its digest in the GKE overlay. Everything comes from models/models.lock.yaml.
# Usage: scripts/build-model-image.sh <tag>      e.g. v1
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$ROOT/models/models.lock.yaml"
TAG="${1:?usage: build-model-image.sh <tag>}"
PROJECT="${PROJECT_ID:-llm-k8s-experimental}"
REGION="${REGION:-us-central1}"
REPO="llm-lab-images"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT}/${REPO}/model-endpoint:${TAG}"
OVERLAY="$ROOT/deploy/model-endpoint/overlays/gke/kustomization.yaml"

lock_value() {
  local value
  value="$(awk -v k="$1" '$1 == k":" { sub(/^[^:]*:[ \t]*/, ""); sub(/[ \t]+#.*$/, ""); print; exit }' "$LOCK")"
  [[ -n "$value" ]] || { echo "lock key '$1' missing" >&2; exit 1; }
  printf '%s' "$value"
}

MODEL_FILE="$(lock_value file)"
MODEL_SHA256="$(lock_value sha256)"
RUNTIME_DIGEST="$(lock_value index_digest)"

[[ -f "$ROOT/models/cache/$MODEL_FILE" ]] || { echo "model missing: run task model:fetch" >&2; exit 1; }
"$ROOT/scripts/fetch-model.sh" >/dev/null   # re-verify hash before baking it in

# Auth to Artifact Registry with the active gcloud identity. Token is passed on stdin, never in argv.
gcloud auth print-access-token | docker login -u oauth2accesstoken --password-stdin "${REGION}-docker.pkg.dev" >/dev/null

docker buildx build \
  --platform linux/amd64 \
  --build-arg "RUNTIME_DIGEST=${RUNTIME_DIGEST}" \
  --build-arg "MODEL_FILE=${MODEL_FILE}" \
  --build-arg "MODEL_SHA256=${MODEL_SHA256}" \
  --provenance=false \
  --sbom=false \
  -f "$ROOT/images/model-endpoint/Dockerfile" \
  -t "$IMAGE" \
  --push \
  "$ROOT"

DIGEST="$(docker buildx imagetools inspect "$IMAGE" --format '{{json .Manifest}}' | python3 -c 'import sys,json; print(json.load(sys.stdin)["digest"])')"
echo "pushed $IMAGE"
echo "digest $DIGEST"

# Record the digest so the deploy is pinned to exactly this artifact, not a mutable tag.
python3 - "$OVERLAY" "$REGION" "$PROJECT" "$REPO" "$DIGEST" <<'PY'
import re, sys
path, region, project, repo, digest = sys.argv[1:]
text = open(path).read()
text = re.sub(r'newName:.*', f'newName: {region}-docker.pkg.dev/{project}/{repo}/model-endpoint', text)
text = re.sub(r'digest:.*', f'digest: {digest}', text)
open(path, "w").write(text)
PY
echo "overlay pinned to $DIGEST"
