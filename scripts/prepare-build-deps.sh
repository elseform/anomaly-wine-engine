#!/usr/bin/env bash
# Fetch, verify and extract the build inputs into build/.
#
#   wine-11.16.tar.xz          upstream Wine (dl.winehq.org)  -> build/wine-11.16/wine
#   llvm-mingw-...tar.xz       PE cross toolchain (GitHub)    -> build/llvm-mingw-...
#
# Each archive is pinned by sha256. A copy in reference/ (OGOM_ARCHIVES_DIR) is
# used when its checksum matches; otherwise the archive is downloaded into
# build/cache/sources/ and verified before use. Nothing has to be supplied by
# hand. The Wine tree is extracted unpatched; scripts/apply-wine-series.sh
# applies patches/series to it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${OGOM:-}" ]]; then
  export OGOM="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

ARCHIVES_DIR="${OGOM_ARCHIVES_DIR:-$OGOM/reference}"
BUILD_DIR="${OGOM_BUILD_DIR:-$OGOM/build}"
CACHE_DIR="$BUILD_DIR/cache/sources"

WINE_VERSION="11.16"
WINE_ARCHIVE="wine-$WINE_VERSION.tar.xz"
WINE_URL="https://dl.winehq.org/wine/source/11.x/$WINE_ARCHIVE"
WINE_SHA256="c66e2090343dcd727f7f7fd2f87ee0bfb0b118790c1d745ab7b8a4c3a4197f2f"
WINE_DIR="$BUILD_DIR/wine-$WINE_VERSION"
WINE_SRC_DIR="$WINE_DIR/wine"

LLVM_MINGW_NAME="llvm-mingw-20260616-ucrt-macos-universal"
LLVM_MINGW_ARCHIVE="$LLVM_MINGW_NAME.tar.xz"
LLVM_MINGW_URL="https://github.com/mstorsjo/llvm-mingw/releases/download/20260616/$LLVM_MINGW_ARCHIVE"
LLVM_MINGW_SHA256="2cab02a2e964bd4aae981150a45985d07c657cfa8d244959eb9e2dcc5eedd7b1"
LLVM_MINGW_DIR="$BUILD_DIR/$LLVM_MINGW_NAME"

DRY_RUN=0
FORCE=0

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '+'
    for arg in "$@"; do
      printf ' %q' "$arg"
    done
    printf '\n'
  else
    "$@"
  fi
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Fetch, verify and extract build inputs into $BUILD_DIR.

Options:
  --force              Extract again even when the targets exist. This deletes
                       $WINE_DIR, including its build64
  --dry-run            Print commands without running them
  -h, --help           Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h | --help)
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

sha256_of() {
  shasum -a 256 "$1" | awk '{print $1}'
}

# Print the path of a verified copy of an archive, downloading it if needed.
fetch_archive() {
  local name="$1" url="$2" sha="$3"
  local local_copy="$ARCHIVES_DIR/$name" cached="$CACHE_DIR/$name"

  if [[ -f "$local_copy" && "$(sha256_of "$local_copy")" == "$sha" ]]; then
    printf '%s\n' "$local_copy"
    return 0
  fi
  if [[ -f "$cached" && "$(sha256_of "$cached")" == "$sha" ]]; then
    printf '%s\n' "$cached"
    return 0
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "+ curl -fL -o $cached $url (sha256 $sha)" >&2
    printf '%s\n' "$cached"
    return 0
  fi
  mkdir -p "$CACHE_DIR"
  echo "Downloading $url" >&2
  curl -fsSL --retry 3 -o "$cached.part" "$url" || {
    rm -f "$cached.part"
    echo "Could not download $url" >&2
    return 1
  }
  if [[ "$(sha256_of "$cached.part")" != "$sha" ]]; then
    echo "$name: sha256 $(sha256_of "$cached.part") does not match the pinned $sha" >&2
    rm -f "$cached.part"
    return 1
  fi
  mv "$cached.part" "$cached"
  printf '%s\n' "$cached"
}

ensure_llvm_mingw() {
  local marker="$LLVM_MINGW_DIR/bin/x86_64-w64-mingw32-clang" archive
  if [[ -x "$marker" && "$FORCE" -eq 0 ]]; then
    echo "llvm-mingw already present at $LLVM_MINGW_DIR"
    return 0
  fi
  archive="$(fetch_archive "$LLVM_MINGW_ARCHIVE" "$LLVM_MINGW_URL" "$LLVM_MINGW_SHA256")"
  if [[ -d "$LLVM_MINGW_DIR" ]]; then
    run rm -rf "$LLVM_MINGW_DIR"
  fi
  echo "Extracting llvm-mingw to $BUILD_DIR"
  run mkdir -p "$BUILD_DIR"
  run tar -xJf "$archive" -C "$BUILD_DIR"
  [[ "$DRY_RUN" -eq 1 || -x "$marker" ]] || {
    echo "llvm-mingw extract failed: missing $marker" >&2
    exit 1
  }
}

ensure_wine_sources() {
  local marker="$WINE_SRC_DIR/configure.ac" archive
  if [[ -f "$marker" && "$FORCE" -eq 0 ]]; then
    echo "Wine $WINE_VERSION sources already present at $WINE_SRC_DIR"
    return 0
  fi
  archive="$(fetch_archive "$WINE_ARCHIVE" "$WINE_URL" "$WINE_SHA256")"
  if [[ -d "$WINE_DIR" ]]; then
    echo "Removing existing $WINE_DIR"
    run rm -rf "$WINE_DIR"
  fi
  echo "Extracting Wine $WINE_VERSION to $WINE_SRC_DIR"
  run mkdir -p "$WINE_DIR"
  run tar -xJf "$archive" -C "$WINE_DIR"
  run mv "$WINE_DIR/wine-$WINE_VERSION" "$WINE_SRC_DIR"
  [[ "$DRY_RUN" -eq 1 || -f "$marker" ]] || {
    echo "Wine extract failed: missing $marker" >&2
    exit 1
  }
}

ensure_llvm_mingw
ensure_wine_sources

echo "Prepare complete."
