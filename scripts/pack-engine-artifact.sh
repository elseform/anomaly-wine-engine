#!/usr/bin/env bash
# Build reusable Wine engine artifact (strip + compressed tar) for GAMMA.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=engine-common.sh
source "$SCRIPT_DIR/engine-common.sh"
MEDIA_PROFILE="${GAMMA_ENGINE_MEDIA_PROFILE:-${CYDER_ENGINE_MEDIA_PROFILE:-minimal}}"
MEDIA_INSTALL_WAS_EXPLICIT="${MEDIA_INSTALL+x}"
source "$SCRIPT_DIR/env-x86_64.sh"

FORCE=0
DRY_RUN=0
FORMAT="${GAMMA_ENGINE_FORMAT:-${CYDER_ENGINE_FORMAT:-xz}}"
# Compression effort. The old defaults (xz -9e / zstd -22 --ultra) cost several
# minutes for a few MB; -6 and -12 land within a few percent in a fraction of
# the time. Override with GAMMA_ENGINE_COMPRESS_LEVEL.
XZ_LEVEL="${GAMMA_ENGINE_COMPRESS_LEVEL:-6}"
ZSTD_LEVEL="${GAMMA_ENGINE_COMPRESS_LEVEL:-12}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      FORCE=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --format)
      FORMAT="${2:-}"
      if [[ -z "$FORMAT" ]]; then
        echo "Missing value for --format" >&2
        exit 1
      fi
      shift 2
      ;;
    --zst | --zstd)
      FORMAT="zst"
      shift
      ;;
    --xz)
      FORMAT="xz"
      shift
      ;;
    --media-profile)
      MEDIA_PROFILE="${2:-}"
      if [[ -z "$MEDIA_PROFILE" ]]; then
        echo "Missing value for --media-profile" >&2
        exit 1
      fi
      shift 2
      ;;
    -h | --help)
      cat <<EOF
Usage: $(basename "$0") [--force] [--dry-run] [--zstd] [--format zstd|xz]
       [--media-profile full-video|minimal]

Build a compressed engine artifact from install/wine-cx26-x86_64 (or WINE_INSTALL).
  xz:   dist/artifacts/CX26W11-Gamma086-<N>.tar.xz (default, xz -$XZ_LEVEL)
  zstd: dist/artifacts/CX26W11-Gamma086-<N>.tar.zst (--zstd)
Set CYDER_ENGINE_VERSION to override the detected version label.
Set GAMMA_ENGINE_FORMAT=zstd or pass --zstd to build with zstd -$ZSTD_LEVEL.
Set GAMMA_ENGINE_COMPRESS_LEVEL to trade size against packing time.
The default media profile is minimal (no GStreamer full-video plugin set);
pass --media-profile full-video only if a video-capable build is needed.
EOF
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

case "$FORMAT" in
  zstd) FORMAT="zst" ;;
esac

case "$MEDIA_PROFILE" in
  full-video)
    if [[ -z "$MEDIA_INSTALL_WAS_EXPLICIT" ]]; then
      MEDIA_INSTALL="$OGOM/install/media-cx${CX_VERSION}-full-video-x86_64"
    fi
    [[ -d "$MEDIA_INSTALL/lib/gstreamer-1.0" ]] || {
      echo "Missing full-video GStreamer plugins at $MEDIA_INSTALL" >&2
      echo "Build them with: bash scripts/build-media-stack.sh --cx $CX_VERSION --full-video" >&2
      exit 1
    }
    [[ -x "$MEDIA_INSTALL/libexec/gstreamer-1.0/gst-plugin-scanner" ]] || {
      echo "Missing full-video GStreamer plugin scanner at $MEDIA_INSTALL" >&2
      echo "Rebuild the media stack with: bash scripts/build-media-stack.sh --cx $CX_VERSION --full-video" >&2
      exit 1
    }
    ;;
  minimal)
    if [[ -z "$MEDIA_INSTALL_WAS_EXPLICIT" ]]; then
      MEDIA_INSTALL="$OGOM/install/media-cx${CX_VERSION}-x86_64"
    fi
    ;;
  *)
    echo "Unknown media profile: $MEDIA_PROFILE (expected full-video or minimal)" >&2
    exit 1
    ;;
esac
export MEDIA_INSTALL

case "$FORMAT" in
  zst | xz) ;;
  *)
    echo "Unknown format: $FORMAT (expected zstd or xz)" >&2
    exit 1
    ;;
esac

[[ -x "$WINE_INSTALL/bin/wine" ]] || {
  echo "Missing Wine at $WINE_INSTALL — build it first." >&2
  exit 1
}
CXCOMPATDB="$WINE_INSTALL/lib/wine/x86_64-unix/cxcompatdb.so"
[[ -f "$CXCOMPATDB" ]] || {
  echo "Missing cxcompatdb at $CXCOMPATDB — run scripts/build-cxcompatdb.sh." >&2
  exit 1
}
CXCOMPATDB_DEBUG_DUMMY="$WINE_INSTALL/lib/wine/x86_64-unix/cxcompatdb-debug_dummy.so"
[[ -f "$CXCOMPATDB_DEBUG_DUMMY" ]] || {
  echo "Missing debug_dummy cxcompatdb at $CXCOMPATDB_DEBUG_DUMMY — run a full scripts/build-wine.sh build." >&2
  exit 1
}
strings -a "$CXCOMPATDB_DEBUG_DUMMY" | grep -q 'GAMMA_CXCOMPATDB_VARIANT=debug_dummy' || {
  echo "Invalid debug_dummy cxcompatdb marker: $CXCOMPATDB_DEBUG_DUMMY" >&2
  exit 1
}
if [[ "$FORMAT" == "zst" ]]; then
  ZSTD_BIN="$(gamma_find_zstd 2>/dev/null || true)"
  [[ -x "$ZSTD_BIN" ]] || {
    echo "Missing zstd — install with: brew install zstd (or set GAMMA_ZSTD=/path/to/zstd)" >&2
    exit 1
  }
else
  command -v xz >/dev/null 2>&1 || {
    echo "Missing xz — install with: brew install xz" >&2
    exit 1
  }
fi

ENGINE_VERSION_LABEL="${GAMMA_ENGINE_VERSION_LABEL:-${CYDER_ENGINE_VERSION_LABEL:-}}"
if [[ -z "$ENGINE_VERSION_LABEL" ]]; then
  ENGINE_VERSION_LABEL="$(head -n 1 "$OGOM/config/engine-version.txt" 2>/dev/null || true)"
fi
if [[ -z "$ENGINE_VERSION_LABEL" ]]; then
  ENGINE_VERSION_LABEL="$(gamma_detect_engine_version_label "$WINE_INSTALL/bin/wine")" || {
    echo "Could not detect engine version from config or wine --version" >&2
    exit 1
  }
fi
ENGINE_VERSION_SLUG="$(gamma_engine_version_slug_from_label "$ENGINE_VERSION_LABEL")"
ENGINE_VERSION="$ENGINE_VERSION_SLUG"
ARTIFACTS_DIR="$(gamma_engine_artifacts_dir)"
ARCHIVE="$(gamma_engine_archive_path_for_format "$ENGINE_VERSION_LABEL" "$ARTIFACTS_DIR" "$FORMAT")"
VERSION_FILE="$ARTIFACTS_DIR/engine-version.txt"
STAMP_FILE="$ARTIFACTS_DIR/.pack-stamp"

if [[ -f "$ARCHIVE" && "$FORCE" -ne 1 ]]; then
  echo "Engine artifact present: $ARCHIVE"
  echo "Use --force to rebuild."
  exit 0
fi

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/gamma-engine-pack.XXXXXX")"
cleanup() {
  rm -rf "$STAGING"
}
trap cleanup EXIT
ENGINE_TREE="$STAGING/wswine.bundle"

echo "==> Staging engine tree ($ENGINE_VERSION_LABEL)"
echo "==> Embedding GStreamer media profile $MEDIA_PROFILE from $MEDIA_INSTALL"
# Stage the engine tree
rsync -a --delete \
  --exclude 'lib/*.bak-*' \
  "$WINE_INSTALL/" "$ENGINE_TREE/"
find "$ENGINE_TREE" -name '.DS_Store' -delete 2>/dev/null || true
gamma_write_engine_version_file "$ENGINE_TREE" "$ENGINE_VERSION_LABEL"

REDIST_SRC="$OGOM/runtime/redist"
[[ -d "$REDIST_SRC/x86_64-windows" ]] || {
  echo "Missing vendored redist DLLs at $REDIST_SRC — see runtime/redist/README or interactive-setup.sh history." >&2
  exit 1
}
echo "==> Embedding vendored DirectX/VC++ redistributables"
rsync -a --delete "$REDIST_SRC/" "$ENGINE_TREE/redist/"

bash "$SCRIPT_DIR/strip-wine-install.sh" "$ENGINE_TREE"
# Preserve MoltenVK already in the install tree (VULKAN_SOURCE=existing only
# seeds it when VULKAN_MODE=with; default without would orphan-delete it).
VULKAN_MODE="${VULKAN_MODE:-with}" VULKAN_SOURCE=existing \
  bash "$SCRIPT_DIR/bundle-wine-dylibs.sh" "$ENGINE_TREE"

bash "$SCRIPT_DIR/sign-wine.sh" --root "$ENGINE_TREE" --entitlements "$ENTITLEMENTS_PLIST"

PACKED_CXCOMPATDB="$ENGINE_TREE/lib/wine/x86_64-unix/cxcompatdb.so"
[[ -f "$PACKED_CXCOMPATDB" ]] || {
  echo "Refusing to pack without cxcompatdb.so" >&2
  exit 1
}
strings -a "$PACKED_CXCOMPATDB" | grep -Eq 'GAMMA_ACTIVE_GRAPHICS_BACKEND_PATH|GRAPHICS_BACKEND_PATH|CYDER_GRAPHICS_BACKEND_PATH' || {
  echo "Refusing to pack an incompatible cxcompatdb.so" >&2
  exit 1
}
[[ -f "$ENGINE_TREE/lib/wine/x86_64-unix/cxcompatdb-debug_dummy.so" ]] || {
  echo "Refusing to pack without cxcompatdb-debug_dummy.so" >&2
  exit 1
}
strings -a "$ENGINE_TREE/lib/wine/x86_64-unix/cxcompatdb-debug_dummy.so" | grep -q 'GAMMA_CXCOMPATDB_VARIANT=debug_dummy' || {
  echo "Refusing to pack an invalid cxcompatdb-debug_dummy.so" >&2
  exit 1
}

# Fail closed: every host Mach-O must stay at/below the product minOS floor.
python3 "$SCRIPT_DIR/pack-minos-scan.py" "$ENGINE_TREE" "${MACOSX_DEPLOYMENT_TARGET:-10.15}"
NTDLL="$ENGINE_TREE/lib/wine/x86_64-windows/ntdll.dll"
[[ -f "$NTDLL" ]] || {
  echo "Missing packaged NTDLL: $NTDLL" >&2
  exit 1
}
NTDLL_SHA256="$(shasum -a 256 "$NTDLL" | awk '{print $1}')"
bash "$SCRIPT_DIR/write-engine-manifest.sh" \
  --output "$ENGINE_TREE/engine-manifest.json" \
  --version "$ENGINE_VERSION_LABEL" \
  --ntdll-sha256 "$NTDLL_SHA256"

mkdir -p "$ARTIFACTS_DIR"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "DRY RUN: would create $ARCHIVE from $ENGINE_TREE"
  exit 0
fi

case "$FORMAT" in
  zst)
    echo "==> Compressing with zstd (-$ZSTD_LEVEL)"
    (
      cd "$STAGING"
      tar -cf - wswine.bundle | "$ZSTD_BIN" "-$ZSTD_LEVEL" -T0 -o "$ARCHIVE"
    )
    ;;
  xz)
    echo "==> Compressing with xz (-$XZ_LEVEL -T0)"
    (
      cd "$STAGING"
      tar -cf - wswine.bundle | xz "-$XZ_LEVEL" -T0 -c >"$ARCHIVE"
    )
    ;;
esac

# Verify the archive itself, not only the staging tree. This catches signatures
# whose embedded CMS data does not survive the final tar round trip.
VERIFY_ROOT="$STAGING/archive-verify"
mkdir -p "$VERIFY_ROOT"
case "$FORMAT" in
  zst)
    "$ZSTD_BIN" -dc "$ARCHIVE" | tar -xf - -C "$VERIFY_ROOT"
    ;;
  xz)
    tar -xJf "$ARCHIVE" -C "$VERIFY_ROOT"
    ;;
esac
verified_macho=0
while IFS= read -r -d '' signed_path; do
  if file -b "$signed_path" | grep -q 'Mach-O'; then
    codesign --verify --strict "$signed_path"
    verified_macho=$((verified_macho + 1))
  fi
done < <(find "$VERIFY_ROOT/wswine.bundle" -type f -print0)
echo "==> Verified $verified_macho Mach-O signatures after archive extraction"

printf '%s\n' "$ENGINE_VERSION_LABEL" >"$VERSION_FILE"
{
  echo "version=$ENGINE_VERSION_LABEL"
  echo "slug=$ENGINE_VERSION_SLUG"
  echo "format=$FORMAT"
  echo "archive=$(basename "$ARCHIVE")"
  if [[ -n "${CYDER_ENGINE_VERSION_LABEL:-}" ]]; then
    echo "wine=$ENGINE_VERSION_LABEL"
  else
    echo "wine=$(arch -x86_64 "$WINE_INSTALL/bin/wine" --version 2>/dev/null || true)"
  fi
  echo "packed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >"$STAMP_FILE"
ARTIFACT_SHA256="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
printf '%s  %s\n' "$ARTIFACT_SHA256" "$(basename "$ARCHIVE")" >"${ARCHIVE}.sha256"
bash "$SCRIPT_DIR/write-engine-manifest.sh" \
  --output "${ARCHIVE}.manifest.json" \
  --version "$ENGINE_VERSION_LABEL" \
  --ntdll-sha256 "$NTDLL_SHA256" \
  --artifact "$(basename "$ARCHIVE")" \
  --artifact-sha256 "$ARTIFACT_SHA256"

echo "==> Created $ARCHIVE ($(du -sh "$ARCHIVE" | awk '{print $1}'))"
echo "==> Version file: $VERSION_FILE"
echo "==> Manifest: ${ARCHIVE}.manifest.json"
