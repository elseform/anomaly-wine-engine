#!/usr/bin/env bash
# Fetch and verify a DXMT build published as a release of elseform/dxmt.
#
#   fetch-dxmt-release.sh [--tag TAG] [--resolve-only]
#
# Without --tag, picks the newest release whose tag is anomaly-YYYY.MM.DD or,
# for a further release on the same day, anomaly-YYYY.MM.DD.N (drafts and
# prereleases ignored), using the anonymous GitHub API. Each
# release carries dxmt-macos-x86_64-<tag>.tar.gz, its .sha256, and a
# .manifest.json listing every payload file's sha256.
#
# The assets are cached in build/cache/dxmt/<tag>/. Every run verifies them
# again: the tarball against its .sha256, then each extracted file against
# the manifest, and the file set against the eight expected DXMT files. Any
# mismatch is fatal and never retried; delete the cache directory to fetch
# again.
#
# Prints key=value lines on stdout: tag, commit, archive_sha256, payload
# (the verified payload directory), cached (yes/no, before this run). With
# --resolve-only, nothing is downloaded and only tag and cached are printed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO="${ANOMALY_DXMT_REPO:-elseform/dxmt}"
CACHE_ROOT="${ANOMALY_DXMT_CACHE:-$ROOT/build/cache/dxmt}"

TAG=""
RESOLVE_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      TAG="${2:-}"
      [[ -n "$TAG" ]] || { echo "Missing value for --tag" >&2; exit 1; }
      shift 2
      ;;
    --resolve-only)
      RESOLVE_ONLY=1
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

EXPECTED_FILES=(
  x86_64-unix/winemetal.so
  x86_64-windows/d3d10core.dll
  x86_64-windows/d3d11.dll
  x86_64-windows/d3d12.dll
  x86_64-windows/dxgi.dll
  x86_64-windows/nvapi64.dll
  x86_64-windows/nvngx.dll
  x86_64-windows/winemetal.dll
)

if [[ -z "$TAG" ]]; then
  TAG="$(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=30" | python3 -c '
import json, re, sys
tags = [r["tag_name"] for r in json.load(sys.stdin)
        if not r.get("draft") and not r.get("prerelease")
        and re.fullmatch(r"anomaly-\d{4}\.\d{2}\.\d{2}(\.\d+)?", r["tag_name"])]
if not tags:
    sys.exit("no anomaly-YYYY.MM.DD release found")
print(max(tags, key=lambda t: [int(x) for x in t[len("anomaly-"):].split(".")]))
')" || { echo "Could not resolve the latest DXMT release of $REPO" >&2; exit 1; }
fi
[[ "$TAG" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Unsafe DXMT tag: $TAG" >&2; exit 1; }

BASE="dxmt-macos-x86_64-$TAG"
CACHE="$CACHE_ROOT/$TAG"
CACHED=no
[[ -f "$CACHE/$BASE.tar.gz" && -f "$CACHE/$BASE.tar.gz.sha256" && -f "$CACHE/$BASE.manifest.json" ]] && CACHED=yes

if [[ "$RESOLVE_ONLY" -eq 1 ]]; then
  printf 'tag=%s\ncached=%s\n' "$TAG" "$CACHED"
  exit 0
fi

if [[ "$CACHED" == no ]]; then
  mkdir -p "$CACHE"
  for asset in "$BASE.tar.gz" "$BASE.tar.gz.sha256" "$BASE.manifest.json"; do
    echo "==> Downloading $REPO $TAG: $asset" >&2
    curl -fsSL -o "$CACHE/$asset.part" "https://github.com/$REPO/releases/download/$TAG/$asset" || {
      rm -f "$CACHE/$asset.part"
      echo "Could not download $asset from $REPO release $TAG" >&2
      exit 1
    }
    mv "$CACHE/$asset.part" "$CACHE/$asset"
  done
fi

EXPECTED_SHA="$(awk '{print $1; exit}' "$CACHE/$BASE.tar.gz.sha256")"
ACTUAL_SHA="$(shasum -a 256 "$CACHE/$BASE.tar.gz" | awk '{print $1}')"
[[ "$EXPECTED_SHA" =~ ^[0-9a-f]{64}$ && "$ACTUAL_SHA" == "$EXPECTED_SHA" ]] || {
  echo "DXMT $TAG tarball checksum mismatch ($ACTUAL_SHA, expected $EXPECTED_SHA)." >&2
  echo "Delete $CACHE to download it again." >&2
  exit 1
}

PAYLOAD="$CACHE/payload"
rm -rf "$PAYLOAD"
mkdir -p "$PAYLOAD"
tar -xzf "$CACHE/$BASE.tar.gz" -C "$PAYLOAD"

# The manifest lists files as payload/<arch>/<name> with "sha256:<hex>".
COMMIT="$(python3 - "$CACHE/$BASE.manifest.json" "$PAYLOAD" "$TAG" "${EXPECTED_FILES[@]}" <<'PY'
import hashlib, json, os, sys

manifest_path, payload, tag, *expected = sys.argv[1:]
manifest = json.load(open(manifest_path, encoding="utf-8"))
if manifest.get("variant_tag") not in (None, tag):
    sys.exit(f"manifest is for tag {manifest.get('variant_tag')}, not {tag}")
listed = {}
for name, digest in manifest.get("files", {}).items():
    rel = name[len("payload/"):] if name.startswith("payload/") else name
    listed[rel] = digest.split(":", 1)[-1]
present = sorted(
    os.path.relpath(os.path.join(d, f), payload)
    for d, _, files in os.walk(payload) for f in files
)
if present != sorted(expected):
    sys.exit(f"payload files {present} differ from the expected {sorted(expected)}")
for rel in expected:
    if rel not in listed:
        sys.exit(f"manifest lists no checksum for {rel}")
    with open(os.path.join(payload, rel), "rb") as stream:
        actual = hashlib.sha256(stream.read()).hexdigest()
    if actual != listed[rel]:
        sys.exit(f"{rel}: sha256 {actual} does not match the manifest's {listed[rel]}")
print(manifest.get("variant_commit") or "")
PY
)" || {
  echo "DXMT $TAG payload failed verification. Delete $CACHE to download it again." >&2
  exit 1
}

printf 'tag=%s\ncommit=%s\narchive_sha256=%s\npayload=%s\ncached=%s\n' \
  "$TAG" "$COMMIT" "$ACTUAL_SHA" "$PAYLOAD" "$CACHED"
