#!/usr/bin/env bash
# Publish an already-built dist/artifacts/*.tar.zst (or .tar.xz) engine
# archive as a GitHub Release, so gamma-setup-tool can download it at
# runtime instead of requiring a local build.
#
# This does NOT build the engine — that happens locally per docs/building.md
# (build-wine.sh, then pack-engine-artifact.sh).
# This script only uploads an artifact that already exists on disk.
#
# Requires the `gh` CLI, authenticated against a GitHub account with push
# access to this repo.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GH_REPO="${GH_REPO:-elseform/gamma-wine-engine}"

DRY_RUN=0
ARTIFACT_PATH=""
NOTES_FILE=""

usage() {
  cat << 'EOF'
Usage: publish-release.sh [--artifact PATH] [--notes-file PATH] [--dry-run]

  --artifact PATH   Engine archive to publish (default: newest
                     dist/artifacts/*.tar.zst or *.tar.xz).
  --notes-file PATH Release notes (Markdown) to put at the top of the release
                     description, above the generated block with the archive
                     name, checksum, DXMT release and requirements.
  --dry-run         Print the planned `gh release create` command and exit
                     without publishing anything.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --artifact)
      ARTIFACT_PATH="${2:-}"
      shift 2
      ;;
    --notes-file)
      NOTES_FILE="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$ARTIFACT_PATH" ]]; then
  ARTIFACT_PATH="$(ls -t "$REPO_ROOT"/dist/artifacts/*.tar.zst "$REPO_ROOT"/dist/artifacts/*.tar.xz 2>/dev/null | head -n 1 || true)"
fi
[[ -n "$ARTIFACT_PATH" && -f "$ARTIFACT_PATH" ]] || {
  echo "Error: no engine archive found. Pass --artifact PATH or build one first (pack-engine-artifact.sh)." >&2
  exit 1
}

MANIFEST_PATH="$ARTIFACT_PATH.manifest.json"
SHA256_PATH="$ARTIFACT_PATH.sha256"
[[ -f "$MANIFEST_PATH" ]] || {
  echo "Error: missing manifest: $MANIFEST_PATH (re-run pack-engine-artifact.sh)" >&2
  exit 1
}
[[ -f "$SHA256_PATH" ]] || {
  echo "Error: missing checksum: $SHA256_PATH (re-run pack-engine-artifact.sh)" >&2
  exit 1
}

command -v gh > /dev/null 2>&1 || {
  echo "Error: the 'gh' CLI is required (brew install gh; gh auth login)." >&2
  exit 1
}

ENGINE_ID="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['engineId'])" "$MANIFEST_PATH")"
VERSION_LABEL="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['versionLabel'])" "$MANIFEST_PATH")"
# Only an archive whose DXMT came from a verified elseform/dxmt release is
# publishable; a --dxmt local test pack is refused.
DXMT_TAG="$(python3 -c "
import json, sys
dxmt = json.load(open(sys.argv[1])).get('dxmt') or {}
if dxmt.get('source') != 'release' or not dxmt.get('tag'):
    sys.exit('the archive was not packed from an elseform/dxmt release (dxmt.source is %r)' % dxmt.get('source'))
print(dxmt['tag'])
" "$MANIFEST_PATH")" || {
  echo "Refusing to publish $MANIFEST_PATH" >&2
  exit 1
}

ARTIFACT_BASENAME="$(basename "$ARTIFACT_PATH")"
# Trailing "-<N>" build counter already present in the artifact filename
# (e.g. CX26-W11-GAMMA-19.tar.xz -> 19), reused as the release/tag
# counter so re-running pack-engine-artifact.sh and this script stay in
# lockstep without a separate version bump step.
BUILD_NUMBER="$(printf '%s\n' "$ARTIFACT_BASENAME" | sed -E 's/\.tar\.(zst|xz)$//; s/.*-([0-9]+)$/\1/')"
TAG="engine-${ENGINE_ID}-${BUILD_NUMBER}"
TITLE="${VERSION_LABEL}-${BUILD_NUMBER}"

if [[ -n "$NOTES_FILE" ]]; then
  [[ -f "$NOTES_FILE" ]] || {
    echo "Error: release notes file not found: $NOTES_FILE" >&2
    exit 1
  }
fi

TECHNICAL_NOTES="Engine: ${VERSION_LABEL}
Artifact: ${ARTIFACT_BASENAME}
SHA256: $(cut -d' ' -f1 "$SHA256_PATH")

DXMT: [${DXMT_TAG}](https://github.com/elseform/dxmt/releases/tag/${DXMT_TAG})

Requires an Apple Silicon Mac running macOS 26 or newer.
Built per docs/building.md; see config/engine-release.json for the full patch list."

if [[ -n "$NOTES_FILE" ]]; then
  NOTES="$(cat "$NOTES_FILE")

$TECHNICAL_NOTES"
else
  NOTES="$TECHNICAL_NOTES"
fi

echo "Tag:      $TAG"
echo "Title:    $TITLE"
echo "Repo:     $GH_REPO"
echo "Artifact: $ARTIFACT_PATH"
echo "Manifest: $MANIFEST_PATH"
echo "Checksum: $SHA256_PATH"
echo "Notes:    ${NOTES_FILE:-(generated block only)}"
echo

CMD=(gh release create "$TAG"
  "$ARTIFACT_PATH" "$MANIFEST_PATH" "$SHA256_PATH"
  --repo "$GH_REPO"
  --title "$TITLE"
  --notes "$NOTES"
)

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry run — would execute:"
  printf '  %q' "${CMD[@]}"
  echo
  exit 0
fi

"${CMD[@]}"
