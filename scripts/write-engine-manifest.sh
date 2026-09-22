#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

OUTPUT=""
VERSION_LABEL=""
BUILD_NUMBER=""
NTDLL_SHA256=""
ARTIFACT=""
ARTIFACT_SHA256=""
RELEASE_CONFIG="${GAMMA_ENGINE_RELEASE_CONFIG:-$ROOT/config/engine-release.json}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) OUTPUT="$2"; shift 2 ;;
    --version) VERSION_LABEL="$2"; shift 2 ;;
    --build-number) BUILD_NUMBER="$2"; shift 2 ;;
    --ntdll-sha256) NTDLL_SHA256="$2"; shift 2 ;;
    --artifact) ARTIFACT="$2"; shift 2 ;;
    --artifact-sha256) ARTIFACT_SHA256="$2"; shift 2 ;;
    --config) RELEASE_CONFIG="$2"; shift 2 ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

[[ -n "$OUTPUT" && -n "$VERSION_LABEL" && -n "$NTDLL_SHA256" ]] || {
  echo "Usage: $(basename "$0") --output FILE --version LABEL --ntdll-sha256 HEX [--build-number N] [--config FILE] [--artifact NAME --artifact-sha256 HEX]" >&2
  exit 1
}
[[ "$VERSION_LABEL" =~ ^[A-Za-z0-9._()[:space:]-]+$ ]] || {
  echo "Unsafe engine version label: $VERSION_LABEL" >&2
  exit 1
}
[[ "$NTDLL_SHA256" =~ ^[0-9a-f]{64}$ ]] || {
  echo "Invalid NTDLL SHA-256" >&2
  exit 1
}
if [[ -n "$BUILD_NUMBER" && ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Invalid build number: $BUILD_NUMBER" >&2
  exit 1
fi
if [[ -n "$ARTIFACT_SHA256" && ! "$ARTIFACT_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "Invalid artifact SHA-256" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"
[[ -f "$RELEASE_CONFIG" ]] || {
  echo "Missing engine release metadata: $RELEASE_CONFIG" >&2
  exit 1
}

# Keep the release identity, compatibility floor, architectures, and ordered
# patch list in one canonical file. The version and checksums are build outputs
# and intentionally replace their config counterparts here.
python3 - "$RELEASE_CONFIG" "$OUTPUT" "$VERSION_LABEL" "$NTDLL_SHA256" \
  "$ARTIFACT" "$ARTIFACT_SHA256" "$BUILD_NUMBER" <<'PY'
import json
import sys

config_path, output_path, version, ntdll_sha, artifact, artifact_sha, build_number = sys.argv[1:]
with open(config_path, encoding="utf-8") as stream:
    manifest = json.load(stream)

manifest["versionLabel"] = version
manifest["buildNumber"] = int(build_number) if build_number else None
manifest["ntdllSHA256"] = ntdll_sha
manifest["artifact"] = artifact or None
manifest["artifactSHA256"] = artifact_sha or None

with open(output_path, "w", encoding="utf-8") as stream:
    json.dump(manifest, stream, ensure_ascii=False, indent=2)
    stream.write("\n")
PY

plutil -convert json -o /dev/null -- "$OUTPUT"
echo "Wrote engine manifest: $OUTPUT"
