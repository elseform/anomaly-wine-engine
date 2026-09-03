#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_DIR="${1:-$REPO_ROOT/renderers/dxmt}"

echo "Fetching latest successful DXMT CI build from 3Shain/dxmt (main branch push)..."

RUN_JSON="$(gh run list --repo 3Shain/dxmt --event push --status success --limit 1 --json databaseId,headSha,createdAt)"
RUN_ID="$(echo "$RUN_JSON" | jq -r '.[0].databaseId')"
RUN_SHA="$(echo "$RUN_JSON" | jq -r '.[0].headSha')"

if [[ -z "$RUN_ID" || "$RUN_ID" == "null" ]]; then
  echo "Error: Could not find latest successful push run for 3Shain/dxmt on main branch." >&2
  exit 1
fi

echo "Found latest run ID: $RUN_ID (commit: ${RUN_SHA:0:8})"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Downloading dxmt artifact..."
gh run download "$RUN_ID" --repo 3Shain/dxmt --pattern "dxmt-*" --dir "$TMP_DIR"

TARBALL="$(find "$TMP_DIR" -type f -name 'dxmt-*.tar.gz' | head -n 1)"
if [[ -z "$TARBALL" || ! -f "$TARBALL" ]]; then
  echo "Error: Failed to find dxmt tarball in downloaded artifact." >&2
  exit 1
fi

echo "Extracting $TARBALL to $TARGET_DIR..."
rm -rf "$TARGET_DIR"
mkdir -p "$TARGET_DIR"

tar -xzf "$TARBALL" -C "$TARGET_DIR" --strip-components=1

# No 32-bit games are targeted; drop the CI artifact's i386 build so the
# staged tree stays x86_64-only, matching install-renderers.sh.
rm -rf "$TARGET_DIR/i386-windows"

echo "DXMT (commit: ${RUN_SHA:0:8}) successfully staged at $TARGET_DIR"
ls -la "$TARGET_DIR"
