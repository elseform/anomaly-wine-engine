#!/usr/bin/env bash
set -euo pipefail

ENGINE_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_PROJECT_ROOT="$(cd "$ENGINE_COMMON_DIR/.." && pwd)"

gamma_engine_artifacts_dir() {
  printf '%s\n' "${GAMMA_ENGINE_ARTIFACTS_DIR:-$ENGINE_PROJECT_ROOT/dist/artifacts}"
}

gamma_crossover_version() {
  printf '%s\n' "${GAMMA_CROSSOVER_VERSION:-26.3.0}"
}

gamma_engine_version_label_trim() {
  local ver="$1"
  ver="${ver//$'\r'/}"
  ver="${ver#"${ver%%[![:space:]]*}"}"
  ver="${ver%"${ver##*[![:space:]]}"}"
  printf '%s\n' "$ver"
}

gamma_format_engine_version_from_wine() {
  local wine_bin="${1:-}"
  local wine_raw wine_ver cx_ver
  local version_label="${GAMMA_ENGINE_VERSION_LABEL:-}"
  if [[ -n "$version_label" ]]; then
    gamma_engine_version_label_trim "$version_label"
    return 0
  fi
  if [[ -z "$wine_bin" && -n "${WINE_INSTALL:-}" ]]; then
    wine_bin="$WINE_INSTALL/bin/wine"
  fi
  [[ -x "$wine_bin" ]] || return 1
  wine_raw="$(arch -x86_64 "$wine_bin" --version 2>/dev/null || true)"
  wine_ver="${wine_raw#wine-}"
  cx_ver="$(gamma_crossover_version)"
  printf 'wine crossover %s (wine %s)\n' "$cx_ver" "$wine_ver"
}

gamma_detect_engine_version_label() {
  gamma_format_engine_version_from_wine "${1:-}"
}

gamma_engine_version_slug_from_label() {
  local label="$1"
  local slug cx wine_ver tail
  label="$(gamma_engine_version_label_trim "$label")"
  if [[ "$label" == wine\ crossover\ * ]]; then
    cx="${label#wine crossover }"
    cx="${cx%% (wine *)}"
    wine_ver="${label#* (wine }"
    wine_ver="${wine_ver%)}"
    slug="crossover-${cx}-wine-${wine_ver}"
    slug="${slug// /-}"
    printf '%s\n' "$slug"
    return 0
  fi
  if [[ "$label" == wine\ sikarugir\ * || "$label" == wine\ Sikarugir\ * ]]; then
    tail="${label#wine sikarugir }"
    if [[ "$tail" == "$label" ]]; then
      tail="${label#wine Sikarugir }"
    fi
    slug="sikarugir-${tail}"
    slug="$(printf '%s' "$slug" | tr ' .()/' '-' | tr -s '-')"
    slug="${slug#-}"
    slug="${slug%-}"
    printf '%s\n' "$slug"
    return 0
  fi
  slug="$label"
  slug="$(printf '%s' "$slug" | tr ' .()/' '-' | tr -s '-')"
  slug="${slug#-}"
  slug="${slug%-}"
  printf '%s\n' "$slug"
}

gamma_engine_versions_equal() {
  local left right left_slug right_slug
  left="$(gamma_engine_version_label_trim "${1:-}")"
  right="$(gamma_engine_version_label_trim "${2:-}")"
  [[ -n "$left" && -n "$right" ]] || return 1
  [[ "$left" == "$right" ]] && return 0
  left_slug="$(gamma_engine_version_slug_from_label "$left")"
  right_slug="$(gamma_engine_version_slug_from_label "$right")"
  [[ "$left_slug" == "$right" || "$left" == "$right_slug" || "$left_slug" == "$right_slug" ]]
}

gamma_read_engine_version_file() {
  local engine_root="$1"
  local ver
  [[ -f "$engine_root/version" ]] || return 1
  ver="$(gamma_engine_version_label_trim "$(cat "$engine_root/version")")"
  [[ -n "$ver" ]] || return 1
  printf '%s\n' "$ver"
}

gamma_write_engine_version_file() {
  local engine_root="$1"
  local ver="$2"
  ver="$(gamma_engine_version_label_trim "$ver")"
  [[ -n "$ver" ]] || return 1
  printf '%s\n' "$ver" >"$engine_root/version"
}

gamma_engine_version_from_tarball() {
  local tarball="$1"
  local ver
  ver="$(tar -xOf "$tarball" wswine.bundle/version 2>/dev/null | head -1 || true)"
  ver="$(gamma_engine_version_label_trim "$ver")"
  [[ -n "$ver" ]] || return 1
  printf '%s\n' "$ver"
}

# Archive path for a version label: the label itself plus a build counter,
# e.g. "CX26-W11-GAMMA" -> dist/artifacts/CX26-W11-GAMMA-19.tar.xz. The counter
# is one more than the highest existing archive of the same label. Archives
# named before the label became the file name ("CX26W11-GAMMA-DXMT-<N>") count
# toward it, so numbering continues across the rename instead of restarting
# (gamma-setup-tool orders releases by this counter). See docs/building.md,
# "Versioning".
gamma_engine_archive_path_for_format() {
  local label="$1"
  local dir="${2:-$(gamma_engine_artifacts_dir)}"
  local format="${3:-xz}"
  local ext path name suffix max=0 legacy nullglob_was_set=0
  label="$(gamma_engine_version_label_trim "$label")"
  if [[ ! "$label" =~ ^CX([0-9]+)-W([0-9]+)-GAMMA$ ]]; then
    echo "Unsupported engine version label: $label (expected CX<n>-W<n>-GAMMA)" >&2
    return 1
  fi
  legacy="CX${BASH_REMATCH[1]}W${BASH_REMATCH[2]}-GAMMA-DXMT"
  case "$format" in
    zst | zstd) ext="tar.zst" ;;
    xz) ext="tar.xz" ;;
    *)
      echo "Unknown engine archive format: $format" >&2
      return 1
      ;;
  esac
  if [[ -d "$dir" ]]; then
    shopt -q nullglob && nullglob_was_set=1
    shopt -s nullglob
    for path in "$dir/$label"-*.tar.zst "$dir/$label"-*.tar.xz \
                "$dir/$legacy"-*.tar.zst "$dir/$legacy"-*.tar.xz; do
      name="${path##*/}"
      suffix="${name%.tar.zst}"
      suffix="${suffix%.tar.xz}"
      suffix="${suffix##*-}"
      if [[ "$suffix" =~ ^[0-9]+$ ]] && (( 10#$suffix > max )); then
        max=$((10#$suffix))
      fi
    done
    (( nullglob_was_set )) || shopt -u nullglob
  fi
  printf '%s/%s-%d.%s\n' "$dir" "$label" "$((max + 1))" "$ext"
}

gamma_find_zstd() {
  local candidate
  for candidate in \
    "${GAMMA_ZSTD:-}" \
    "$ENGINE_PROJECT_ROOT/tools/zstd/zstd" \
    "$(command -v zstd 2>/dev/null || true)"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      printf '%s/%s\n' "$(cd "$(dirname "$candidate")" && pwd -P)" "$(basename "$candidate")"
      return 0
    fi
  done
  return 1
}
