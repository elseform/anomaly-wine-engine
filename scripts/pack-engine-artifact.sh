#!/usr/bin/env bash
# Build reusable Wine engine artifact (strip + compressed tar) for GAMMA.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=engine-common.sh
source "$SCRIPT_DIR/engine-common.sh"
source "$SCRIPT_DIR/env-x86_64.sh"

FORCE=0
DRY_RUN=0
BUILD_NUMBER=""
DXMT_LOCAL=""
DXMT_TAG_ARG=""
# xz is the default: macOS tar and Python's lzma unpack it with no extra
# tools, so gamma-setup-tool (which only accepts .tar.xz) needs no zstd.
FORMAT="${GAMMA_ENGINE_FORMAT:-xz}"
# Compression effort. The old xz -9e / zstd -22 --ultra defaults cost minutes
# for negligible distribution benefit. Both default xz and explicit zstd use
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
    --build-number)
      BUILD_NUMBER="${2:-}"
      shift 2
      ;;
    --dxmt)
      DXMT_LOCAL="${2:-}"
      [[ -n "$DXMT_LOCAL" ]] || { echo "Missing value for --dxmt" >&2; exit 1; }
      shift 2
      ;;
    --dxmt-tag)
      DXMT_TAG_ARG="${2:-}"
      [[ -n "$DXMT_TAG_ARG" ]] || { echo "Missing value for --dxmt-tag" >&2; exit 1; }
      shift 2
      ;;
    -h | --help)
      cat <<EOF
Usage: $(basename "$0") [--force] [--dry-run] [--zstd|--xz] [--build-number N]
       [--dxmt-tag TAG | --dxmt DIR]
       [--format zstd|xz]

Build a compressed engine artifact from install/wine-cx26-x86_64 (or WINE_INSTALL).
  xz:   dist/artifacts/CX26-W11-GAMMA-<N>.tar.xz (default, xz -$XZ_LEVEL)
  zstd: dist/artifacts/CX26-W11-GAMMA-<N>.tar.zst (--zstd, zstd -$ZSTD_LEVEL;
        not accepted by gamma-setup-tool)
DXMT is the only graphics backend. It comes from the latest gamma-YYYY.MM.DD[.N]
release of elseform/dxmt (scripts/fetch-dxmt-release.sh, verified and cached
in build/cache/dxmt/), or from --dxmt-tag TAG. --dxmt DIR packs a local,
unreleased payload (x86_64-windows/ and x86_64-unix/) for testing; its
manifest says so and publish-release.sh refuses it.
<N> is config/build-number plus one, or --build-number N. A successful pack
writes <N> back to config/build-number (commit it).
--dry-run performs only a fast source/layout preflight; it does not stage,
strip, rewrite dylib paths, sign, scan minOS, compress, or verify an archive.
Set GAMMA_ENGINE_VERSION_LABEL to override the detected version label.
Set GAMMA_ENGINE_FORMAT=zstd or pass --zstd only for an explicit zstd build.
Set GAMMA_ENGINE_COMPRESS_LEVEL to trade size against packing time.
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
# The -<N> build counter, also recorded in the manifest as buildNumber so a
# consumer never has to parse it out of a filename. gamma-setup-tool orders
# releases by it, so it must keep growing: the last packed number is tracked
# in config/build-number.
BUILD_NUMBER_FILE="$OGOM/config/build-number"
if [[ -z "$BUILD_NUMBER" ]]; then
  last="$(tr -d '[:space:]' <"$BUILD_NUMBER_FILE" 2>/dev/null || true)"
  [[ "$last" =~ ^[0-9]+$ ]] || {
    echo "Cannot read the last build number from $BUILD_NUMBER_FILE; pass --build-number N" >&2
    exit 1
  }
  BUILD_NUMBER=$((10#$last + 1))
fi
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || {
  echo "Invalid build number: $BUILD_NUMBER" >&2
  exit 1
}
ARCHIVE="$(gamma_engine_archive_path_for_format "$ENGINE_VERSION_LABEL" "$ARTIFACTS_DIR" "$FORMAT" "$BUILD_NUMBER")" || exit 1
VERSION_FILE="$ARTIFACTS_DIR/engine-version.txt"
STAMP_FILE="$ARTIFACTS_DIR/.pack-stamp"

# Cheap source preflight. Keep this before mktemp/rsync so --dry-run never
# performs packaging work.
for obsolete in lib/d3dmetal lib/dxvk lib/external lib/gptk40b1 lib/gptk40b2 lib/apple_gptk lib64/apple_gptk; do
  [[ ! -e "$WINE_INSTALL/$obsolete" ]] || {
    echo "Refusing obsolete renderer layout in source engine: $obsolete" >&2
    exit 1
  }
done
# DXMT never comes from the install tree: packing takes it from a verified
# elseform/dxmt release (or an explicit local payload) and puts it into the
# disposable staging tree below. A dry run only resolves the release.
DXMT_NOTICE="$OGOM/renderers/dxmt/NOTICE"
[[ -f "$DXMT_NOTICE" ]] || {
  echo "Missing DXMT license notice at $DXMT_NOTICE" >&2
  exit 1
}
DXMT_FILES=(
  x86_64-unix/winemetal.so
  x86_64-windows/d3d10core.dll x86_64-windows/d3d11.dll x86_64-windows/d3d12.dll
  x86_64-windows/dxgi.dll x86_64-windows/nvapi64.dll x86_64-windows/nvngx.dll
  x86_64-windows/winemetal.dll
)
DXMT_TAG="" DXMT_COMMIT="" DXMT_ARCHIVE_SHA256="" DXMT_PAYLOAD="" DXMT_CACHED=""
if [[ -n "$DXMT_LOCAL" ]]; then
  [[ -z "$DXMT_TAG_ARG" ]] || { echo "Use either --dxmt or --dxmt-tag, not both" >&2; exit 1; }
  DXMT_SOURCE=local
  [[ -d "$DXMT_LOCAL" ]] || { echo "Local DXMT payload not found: $DXMT_LOCAL" >&2; exit 1; }
  DXMT_PAYLOAD="$(cd "$DXMT_LOCAL" && pwd)"
  for rel in "${DXMT_FILES[@]}"; do
    [[ -f "$DXMT_PAYLOAD/$rel" ]] || {
      echo "Local DXMT payload is missing $rel: $DXMT_PAYLOAD" >&2
      exit 1
    }
  done
else
  DXMT_SOURCE=release
  fetch_args=()
  [[ -z "$DXMT_TAG_ARG" ]] || fetch_args+=(--tag "$DXMT_TAG_ARG")
  [[ "$DRY_RUN" -ne 1 ]] || fetch_args+=(--resolve-only)
  fetch_output="$(bash "$SCRIPT_DIR/fetch-dxmt-release.sh" ${fetch_args[@]+"${fetch_args[@]}"})" || exit 1
  while IFS='=' read -r key value; do
    case "$key" in
      tag) DXMT_TAG="$value" ;;
      commit) DXMT_COMMIT="$value" ;;
      archive_sha256) DXMT_ARCHIVE_SHA256="$value" ;;
      payload) DXMT_PAYLOAD="$value" ;;
      cached) DXMT_CACHED="$value" ;;
    esac
  done <<<"$fetch_output"
  [[ -n "$DXMT_TAG" ]] || { echo "Could not resolve a DXMT release" >&2; exit 1; }
  [[ "$DRY_RUN" -eq 1 || -d "$DXMT_PAYLOAD" ]] || { echo "DXMT fetch returned no payload" >&2; exit 1; }
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
strings -a "$CXCOMPATDB" | grep -q 'GAMMA_GRAPHICS_BACKEND' || {
  echo "Refusing to pack an incompatible cxcompatdb.so" >&2
  exit 1
}
strings -a "$CXCOMPATDB" | grep -q '/lib/dxmt' || {
  echo "Refusing to pack cxcompatdb without DXMT backend support" >&2
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
  if [[ "$DXMT_SOURCE" == local ]]; then
    echo "  dxmt: local payload $DXMT_PAYLOAD (not publishable)"
  else
    echo "  dxmt: elseform/dxmt $DXMT_TAG ($([[ "$DXMT_CACHED" == yes ]] && echo cached || echo "not cached, downloaded on pack"))"
  fi
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
# Stage the engine tree
rsync -a --delete \
  --exclude 'lib/*.bak-*' \
  "$WINE_INSTALL/" "$ENGINE_TREE/"
find "$ENGINE_TREE" -name '.DS_Store' -delete 2>/dev/null || true
rm -rf "$ENGINE_TREE/redist"
gamma_write_engine_version_file "$ENGINE_TREE" "$ENGINE_VERSION_LABEL"

# DXMT goes into lib/dxmt, which cxcompatdb puts first on the DLL search path.
# winemetal.dll is also copied into Wine's own lib/wine/x86_64-windows: that is
# the only place wineboot looks when it creates system32/winemetal.dll, and the
# loader refuses a DLL that has no system32 entry. The copy in lib/dxmt is the
# one that loads.
echo "==> Staging DXMT ($([[ "$DXMT_SOURCE" == local ]] && echo "local $DXMT_PAYLOAD" || echo "elseform/dxmt $DXMT_TAG"))"
rm -rf "$ENGINE_TREE/lib/dxmt"
rm -f "$ENGINE_TREE/lib/wine/i386-windows/winemetal.dll"
mkdir -p "$ENGINE_TREE/lib/dxmt/x86_64-windows" "$ENGINE_TREE/lib/dxmt/x86_64-unix"
for rel in "${DXMT_FILES[@]}"; do
  cp "$DXMT_PAYLOAD/$rel" "$ENGINE_TREE/lib/dxmt/$rel"
done
cp "$DXMT_PAYLOAD/x86_64-windows/winemetal.dll" "$ENGINE_TREE/lib/wine/x86_64-windows/winemetal.dll"
cp "$DXMT_NOTICE" "$ENGINE_TREE/lib/dxmt/NOTICE"

[[ -d "$ENGINE_TREE/lib/dxmt/x86_64-windows" ]] || {
  echo "Missing packaged DXMT payload at lib/dxmt" >&2
  exit 1
}
for obsolete in lib/d3dmetal lib/dxvk lib/external lib/gptk40b1 lib/gptk40b2 lib/apple_gptk lib64/apple_gptk; do
  [[ ! -e "$ENGINE_TREE/$obsolete" ]] || {
    echo "Refusing obsolete renderer layout in artifact: $obsolete" >&2
    exit 1
  }
done

echo "==> Embedding the DirectX/VC++ redistributable manifest and fetcher"
mkdir -p "$ENGINE_TREE/share/gamma/redist-fetch"
cp "$REDIST_MANIFEST_SRC" "$ENGINE_TREE/share/gamma/redist-manifest.json"
rsync -a --delete --exclude '__pycache__' \
  "$REDIST_FETCH_SRC/" "$ENGINE_TREE/share/gamma/redist-fetch/"
[[ ! -e "$ENGINE_TREE/share/gamma/redist" ]] || {
  echo "Refusing to pack bundled redist DLLs at share/gamma/redist" >&2
  exit 1
}

# The wrapper UI is supplied by gamma-setup-tool. Remove any legacy copy
# carried by an older install tree from this disposable archive staging tree.
rm -rf "$ENGINE_TREE/share/gamma/Configurator.app"
# Remove Finder metadata introduced while staging.
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
strings -a "$PACKED_CXCOMPATDB" | grep -q '/lib/dxmt' || {
  echo "Refusing to pack cxcompatdb without DXMT backend support" >&2
  exit 1
}
if strings -a "$PACKED_CXCOMPATDB" | grep -q 'CX_ACTIVE_GRAPHICS_BACKEND'; then
  echo "Refusing to pack cxcompatdb with legacy CX_ACTIVE_GRAPHICS_BACKEND policy" >&2
  exit 1
fi

# Fail closed: every host Mach-O must stay at/below the product minOS floor.
python3 "$SCRIPT_DIR/pack-minos-scan.py" "$ENGINE_TREE" "${MACOSX_DEPLOYMENT_TARGET:-10.15}" "${GAMMA_PRODUCT_MIN_OS:-26.0}"
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
  --ntdll-sha256 "$NTDLL_SHA256" \
  --dxmt-source "$DXMT_SOURCE" --dxmt-tag "$DXMT_TAG" \
  --dxmt-commit "$DXMT_COMMIT" --dxmt-sha256 "$DXMT_ARCHIVE_SHA256"

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
  --artifact-sha256 "$ARTIFACT_SHA256" \
  --dxmt-source "$DXMT_SOURCE" --dxmt-tag "$DXMT_TAG" \
  --dxmt-commit "$DXMT_COMMIT" --dxmt-sha256 "$DXMT_ARCHIVE_SHA256"

printf '%s\n' "$BUILD_NUMBER" >"$BUILD_NUMBER_FILE"

echo "==> Created $ARCHIVE ($(du -sh "$ARCHIVE" | awk '{print $1}'))"
echo "==> Build number $BUILD_NUMBER recorded in config/build-number (commit it)"
echo "==> Version file: $VERSION_FILE"
echo "==> Manifest: ${ARCHIVE}.manifest.json"
