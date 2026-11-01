#!/usr/bin/env bash
# Download the model pinned in models/models.lock.yaml and verify its SHA-256 before use.
# Idempotent: a file that already matches the pin is kept. A mismatch deletes the file and fails.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$ROOT/models/models.lock.yaml"
CACHE="$ROOT/models/cache"

# Read `key: value` from the lock file. Fails if the key is missing, so a typo cannot silently
# produce an empty pin.
# Section-aware: the first argument picks a top-level section of the lock file (default: model).
SECTION="${1:-model}"
lock_value() {
  local key="$1" value
  value="$(awk -v k="$key" -v sec="$SECTION" '
    /^[a-zA-Z_]+:/ { insec = ($0 == sec":") ; next }
    insec && $1 == k":" { sub(/^[^:]*:[ \t]*/, ""); sub(/[ \t]+#.*$/, ""); print; exit }' "$LOCK")"
  [[ -n "$value" ]] || { echo "lock key '$key' missing from $LOCK" >&2; exit 1; }
  printf '%s' "$value"
}

URL="$(lock_value url)"
FILE="$(lock_value file)"
SHA256="$(lock_value sha256)"
SIZE="$(lock_value size_bytes)"
DEST="$CACHE/$FILE"

sha_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

mkdir -p "$CACHE"

if [[ -f "$DEST" ]] && [[ "$(sha_of "$DEST")" == "$SHA256" ]]; then
  echo "model OK (already present, sha256 matches pin): $DEST"
  exit 0
fi

echo "downloading $FILE (${SIZE} bytes) from pinned revision"
TMP="$DEST.partial"
curl -fL --retry 3 --retry-delay 5 -o "$TMP" "$URL"

ACTUAL_SIZE="$(wc -c < "$TMP" | tr -d ' ')"   # portable: macOS and Linux runners
if [[ "$ACTUAL_SIZE" != "$SIZE" ]]; then
  rm -f "$TMP"
  echo "size mismatch: expected $SIZE, got $ACTUAL_SIZE. Download discarded." >&2
  exit 1
fi

ACTUAL_SHA="$(sha_of "$TMP")"
if [[ "$ACTUAL_SHA" != "$SHA256" ]]; then
  rm -f "$TMP"
  echo "SHA-256 mismatch. expected $SHA256, got $ACTUAL_SHA. Download discarded; do not serve it." >&2
  exit 1
fi

mv "$TMP" "$DEST"
echo "model OK: $DEST (sha256 $SHA256)"
