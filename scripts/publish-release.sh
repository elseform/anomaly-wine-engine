#!/usr/bin/env bash
# Publish an already-built dist/artifacts/*.tar.zst (or .tar.xz) engine
# archive as a GitHub Release, so gamma-setup-tool can download it at
# runtime instead of requiring a local build.
#
# This does NOT build the engine — that still happens locally or in the
# offline VM per docs/engine/offline-vm-build.md and pack-engine-artifact.sh.
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

usage() {
  cat << 'EOF'
Usage: publish-release.sh [--artifact PATH] [--dry-run]

  --artifact PATH   Engine archive to publish (default: newest
                     dist/artifacts/*.tar.zst or *.tar.xz).
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

ARTIFACT_BASENAME="$(basename "$ARTIFACT_PATH")"
# Trailing "-<N>" build counter already present in the artifact filename
# (e.g. CX26W11-GAMMA-DXMT-5.tar.zst -> 5), reused as the release/tag
# counter so re-running pack-engine-artifact.sh and this script stay in
# lockstep without a separate version bump step.
BUILD_NUMBER="$(printf '%s\n' "$ARTIFACT_BASENAME" | sed -E 's/\.tar\.(zst|xz)$//; s/.*-([0-9]+)$/\1/')"
TAG="engine-${ENGINE_ID}-${BUILD_NUMBER}"

NOTES="Engine: ${VERSION_LABEL}
Artifact: ${ARTIFACT_BASENAME}
SHA256: $(cut -d' ' -f1 "$SHA256_PATH")

Built locally / via the offline VM pipeline (docs/engine/offline-vm-build.md).
See config/engine-release.json for the full patch list."

echo "Tag:      $TAG"
echo "Title:    $VERSION_LABEL"
echo "Repo:     $GH_REPO"
echo "Artifact: $ARTIFACT_PATH"
echo "Manifest: $MANIFEST_PATH"
echo "Checksum: $SHA256_PATH"
echo

CMD=(gh release create "$TAG"
  "$ARTIFACT_PATH" "$MANIFEST_PATH" "$SHA256_PATH"
  --repo "$GH_REPO"
  --title "$VERSION_LABEL"
  --notes "$NOTES"
)

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry run — would execute:"
  printf '  %q' "${CMD[@]}"
  echo
  exit 0
fi

"${CMD[@]}"
