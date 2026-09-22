#!/usr/bin/env bash
# Build reusable Wine engine artifact (strip + compressed tar) for GAMMA.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=engine-common.sh
source "$SCRIPT_DIR/engine-common.sh"
MEDIA_PROFILE="${GAMMA_ENGINE_MEDIA_PROFILE:-minimal}"
MEDIA_INSTALL_WAS_EXPLICIT="${MEDIA_INSTALL+x}"
source "$SCRIPT_DIR/env-x86_64.sh"

FORCE=0
DRY_RUN=0
DXMT_ONLY=0
FORMAT="${GAMMA_ENGINE_FORMAT:-zst}"
# Compression effort. The old xz -9e / zstd -22 --ultra defaults cost minutes
# for negligible distribution benefit. Both explicit xz and default zstd use
# a moderate level 6. Override with GAMMA_ENGINE_COMPRESS_LEVEL.
XZ_LEVEL="${GAMMA_ENGINE_COMPRESS_LEVEL:-6}"
ZSTD_LEVEL="${GAMMA_ENGINE_COMPRESS_LEVEL:-6}"

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
    --dxmt-only)
      DXMT_ONLY=1
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
Usage: $(basename "$0") [--force] [--dry-run] [--dxmt-only] [--zstd|--xz]
       [--format zstd|xz] [--media-profile full-video|minimal]

Build a compressed engine artifact from install/wine-cx26-x86_64 (or WINE_INSTALL).
  zstd: dist/artifacts/CX26W11-Gamma087-<N>.tar.zst (default, zstd -$ZSTD_LEVEL)
  xz:   dist/artifacts/CX26W11-Gamma087-<N>.tar.xz (--xz, xz -$XZ_LEVEL)
GPTK/D3DMetal is optional and user-supplied (see docs/renderers.md): if no
GPTK payload was staged, packing is DXMT-only automatically, producing
dist/artifacts/CX26W11-GAMMA-DXMT-<N>.tar.zst (no numeric engine version in
the filename). --dxmt-only forces this and strips any staged GPTK payload
from the tree even if one is present.
--dry-run performs only a fast source/layout preflight; it does not stage,
strip, rewrite dylib paths, sign, scan minOS, compress, or verify an archive.
Set GAMMA_ENGINE_VERSION_LABEL to override the detected version label.
Set GAMMA_ENGINE_FORMAT=xz or pass --xz only for an explicit xz build.
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

ENGINE_VERSION_LABEL="${GAMMA_ENGINE_VERSION_LABEL:-}"
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
# Read by install-renderers.sh's flag file so the artifact name records which
# GPTK payload (gptk40b1, gptk40b2, ...) got staged into this WINE_INSTALL.
GPTK_VERSION="$(gamma_engine_gptk_version "$WINE_INSTALL")"
# GPTK is optional and user-supplied (see docs/renderers.md): if
# install-renderers.sh wasn't given a GPTK payload, no lib64/apple_gptk was
# staged, so pack DXMT-only automatically instead of hard-failing.
if [[ "$DXMT_ONLY" -ne 1 && ! -d "$WINE_INSTALL/lib64/apple_gptk/wine/x86_64-windows" ]]; then
  echo "==> No staged GPTK/D3DMetal payload — packing DXMT-only (pass --apple-gptk to install-renderers.sh first to include D3DMetal)"
  DXMT_ONLY=1
fi
if [[ "$DXMT_ONLY" -eq 1 ]]; then
  ARCHIVE="$(gamma_engine_dxmt_archive_path_for_format "$ENGINE_VERSION_LABEL" "$ARTIFACTS_DIR" "$FORMAT")"
else
  ARCHIVE="$(gamma_engine_archive_path_for_format "$ENGINE_VERSION_LABEL" "$ARTIFACTS_DIR" "$FORMAT" "$GPTK_VERSION")"
fi
# The -<N> build counter, also recorded in the manifest as buildNumber so a
# consumer never has to parse it out of a filename.
BUILD_NUMBER="$(basename "$ARCHIVE")"
BUILD_NUMBER="${BUILD_NUMBER%%.tar.*}"
BUILD_NUMBER="${BUILD_NUMBER##*-}"
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || {
  echo "Cannot derive the build number from $(basename "$ARCHIVE")" >&2
  exit 1
}
VERSION_FILE="$ARTIFACTS_DIR/engine-version.txt"
STAMP_FILE="$ARTIFACTS_DIR/.pack-stamp"

# Cheap source preflight. Keep this before mktemp/rsync so --dry-run never
# performs packaging work.
if [[ "$DXMT_ONLY" -ne 1 ]]; then
  [[ -d "$WINE_INSTALL/lib64/apple_gptk/wine/x86_64-windows" ]] || {
    echo "Missing packaged D3DMetal payload at lib64/apple_gptk/wine" >&2
    exit 1
  }
fi
[[ -d "$WINE_INSTALL/lib/dxmt/x86_64-windows" ]] || {
  echo "Missing packaged DXMT payload at lib/dxmt" >&2
  exit 1
}
for obsolete in lib/d3dmetal lib/dxvk lib/external lib/gptk40b1 lib/gptk40b2 lib/apple_gptk; do
  [[ ! -e "$WINE_INSTALL/$obsolete" ]] || {
    echo "Refusing obsolete renderer layout in source engine: $obsolete" >&2
    exit 1
  }
done
# The install tree only picks up renderers/dxmt when install-renderers.sh runs,
# so a payload committed since then would silently not ship.
DXMT_PAYLOAD="${DXMT_SRC:-$OGOM/renderers/dxmt}"
dxmt_stale=()
while IFS= read -r -d '' payload_file; do
  rel="${payload_file#"$DXMT_PAYLOAD"/}"
  cmp -s "$payload_file" "$WINE_INSTALL/lib/dxmt/$rel" || dxmt_stale+=("lib/dxmt/$rel")
done < <(find "$DXMT_PAYLOAD/x86_64-windows" "$DXMT_PAYLOAD/x86_64-unix" -type f -print0)
if [[ -f "$DXMT_PAYLOAD/x86_64-windows/winemetal.dll" ]] &&
   ! cmp -s "$DXMT_PAYLOAD/x86_64-windows/winemetal.dll" "$WINE_INSTALL/lib/wine/x86_64-windows/winemetal.dll"; then
  dxmt_stale+=("lib/wine/x86_64-windows/winemetal.dll")
fi
[[ ! -e "$WINE_INSTALL/lib/wine/i386-windows/winemetal.dll" ]] || dxmt_stale+=("lib/wine/i386-windows/winemetal.dll (obsolete)")
if [[ ${#dxmt_stale[@]} -gt 0 ]]; then
  echo "Refusing to pack: the install tree does not match $DXMT_PAYLOAD:" >&2
  printf '  %s\n' "${dxmt_stale[@]}" >&2
  echo "Run scripts/install-renderers.sh $WINE_INSTALL first." >&2
  exit 1
fi
# The Microsoft redistributables are Microsoft's to distribute, not ours, so
# the archive carries a declaration of what it needs plus the code that fetches
# it from Microsoft's own pinned installers at wrapper-setup time.
REDIST_MANIFEST_SRC="$OGOM/config/redist-manifest.json"
REDIST_FETCH_SRC="$OGOM/runtime/redist-fetch"
[[ -f "$REDIST_MANIFEST_SRC" ]] || {
  echo "Missing redist manifest at $REDIST_MANIFEST_SRC — regenerate it with scripts/write-redist-manifest.py." >&2
  exit 1
}
[[ -f "$REDIST_FETCH_SRC/gamma_redist.py" ]] || {
  echo "Missing redist fetcher at $REDIST_FETCH_SRC/gamma_redist.py." >&2
  exit 1
}
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$REDIST_MANIFEST_SRC" || {
  echo "Refusing to pack an unparsable redist manifest: $REDIST_MANIFEST_SRC" >&2
  exit 1
}
CONFIGURATOR_GUI_SRC="$OGOM/runtime/configurator-gui/Sources"
[[ -d "$CONFIGURATOR_GUI_SRC" ]] || {
  echo "Missing configurator GUI source at $CONFIGURATOR_GUI_SRC" >&2
  exit 1
}
strings -a "$CXCOMPATDB" | grep -q 'GAMMA_GRAPHICS_BACKEND' || {
  echo "Refusing to pack an incompatible cxcompatdb.so" >&2
  exit 1
}
strings -a "$CXCOMPATDB" | grep -q 'lib64/apple_gptk/wine' || {
  echo "Refusing to pack cxcompatdb without CrossOver D3DMetal layout support" >&2
  exit 1
}
if strings -a "$CXCOMPATDB" | grep -q 'CX_ACTIVE_GRAPHICS_BACKEND'; then
  echo "Refusing to pack cxcompatdb with legacy CX_ACTIVE_GRAPHICS_BACKEND policy" >&2
  exit 1
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "DRY RUN: preflight passed"
  echo "  source: $WINE_INSTALL"
  echo "  version: $ENGINE_VERSION_LABEL"
  echo "  gptk: ${GPTK_VERSION:-<unlabeled>}"
  echo "  dxmt-only: $([[ "$DXMT_ONLY" -eq 1 ]] && echo yes || echo no)"
  echo "  media: $MEDIA_PROFILE ($MEDIA_INSTALL)"
  echo "  output: $ARCHIVE"
  exit 0
fi

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
rm -rf "$ENGINE_TREE/redist"
gamma_write_engine_version_file "$ENGINE_TREE" "$ENGINE_VERSION_LABEL"

if [[ "$DXMT_ONLY" -ne 1 ]]; then
  [[ -d "$ENGINE_TREE/lib64/apple_gptk/wine/x86_64-windows" ]] || {
    echo "Missing packaged D3DMetal payload at lib64/apple_gptk/wine" >&2
    exit 1
  }
fi
[[ -d "$ENGINE_TREE/lib/dxmt/x86_64-windows" ]] || {
  echo "Missing packaged DXMT payload at lib/dxmt" >&2
  exit 1
}
for obsolete in lib/d3dmetal lib/dxvk lib/external lib/gptk40b1 lib/gptk40b2 lib/apple_gptk; do
  [[ ! -e "$ENGINE_TREE/$obsolete" ]] || {
    echo "Refusing obsolete renderer layout in artifact: $obsolete" >&2
    exit 1
  }
done

if [[ "$DXMT_ONLY" -eq 1 ]]; then
  echo "==> Stripping GPTK/D3DMetal payload (--dxmt-only)"
  rm -rf "$ENGINE_TREE/lib64/apple_gptk"
fi

echo "==> Embedding the DirectX/VC++ redistributable manifest and fetcher"
mkdir -p "$ENGINE_TREE/share/gamma/redist-fetch"
cp "$REDIST_MANIFEST_SRC" "$ENGINE_TREE/share/gamma/redist-manifest.json"
rsync -a --delete --exclude '__pycache__' \
  "$REDIST_FETCH_SRC/" "$ENGINE_TREE/share/gamma/redist-fetch/"
[[ ! -e "$ENGINE_TREE/share/gamma/redist" ]] || {
  echo "Refusing to pack bundled redist DLLs at share/gamma/redist" >&2
  exit 1
}

echo "==> Building GAMMA Configurator (SwiftUI)"
bash "$SCRIPT_DIR/build-configurator.sh" "$STAGING/Configurator.app"
mkdir -p "$ENGINE_TREE/share/gamma"
cp -R "$STAGING/Configurator.app" "$ENGINE_TREE/share/gamma/Configurator.app"
# Sweep again before signing: everything staged after the first sweep (the
# configurator build above included) can carry Finder metadata of its own.
# `._*` are macOS AppleDouble sidecars, which cross-volume copies (SMB, exFAT,
# zip round-trips) leave next to real files.
find "$ENGINE_TREE" \( -name '.DS_Store' -o -name '._*' \) -delete 2>/dev/null || true

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
strings -a "$PACKED_CXCOMPATDB" | grep -q 'GAMMA_GRAPHICS_BACKEND' || {
  echo "Refusing to pack an incompatible cxcompatdb.so" >&2
  exit 1
}
strings -a "$PACKED_CXCOMPATDB" | grep -q 'lib64/apple_gptk/wine' || {
  echo "Refusing to pack cxcompatdb without CrossOver D3DMetal layout support" >&2
  exit 1
}
if strings -a "$PACKED_CXCOMPATDB" | grep -q 'CX_ACTIVE_GRAPHICS_BACKEND'; then
  echo "Refusing to pack cxcompatdb with legacy CX_ACTIVE_GRAPHICS_BACKEND policy" >&2
  exit 1
fi

# Fail closed: every host Mach-O must stay at/below the product minOS floor.
python3 "$SCRIPT_DIR/pack-minos-scan.py" "$ENGINE_TREE" "${MACOSX_DEPLOYMENT_TARGET:-10.15}" "${GAMMA_PRODUCT_MIN_OS:-15.0}"
NTDLL="$ENGINE_TREE/lib/wine/x86_64-windows/ntdll.dll"
[[ -f "$NTDLL" ]] || {
  echo "Missing packaged NTDLL: $NTDLL" >&2
  exit 1
}
NTDLL_SHA256="$(shasum -a 256 "$NTDLL" | awk '{print $1}')"
bash "$SCRIPT_DIR/write-engine-manifest.sh" \
  --output "$ENGINE_TREE/engine-manifest.json" \
  --version "$ENGINE_VERSION_LABEL" \
  --build-number "$BUILD_NUMBER" \
  --ntdll-sha256 "$NTDLL_SHA256"

mkdir -p "$ARTIFACTS_DIR"
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
  if [[ -n "${GAMMA_ENGINE_VERSION_LABEL:-}" ]]; then
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
  --build-number "$BUILD_NUMBER" \
  --ntdll-sha256 "$NTDLL_SHA256" \
  --artifact "$(basename "$ARCHIVE")" \
  --artifact-sha256 "$ARTIFACT_SHA256"

echo "==> Created $ARCHIVE ($(du -sh "$ARCHIVE" | awk '{print $1}'))"
echo "==> Version file: $VERSION_FILE"
echo "==> Manifest: ${ARCHIVE}.manifest.json"
