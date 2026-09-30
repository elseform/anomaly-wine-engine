#!/usr/bin/env bash
set -euo pipefail

ENGINE_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_PROJECT_ROOT="$(cd "$ENGINE_COMMON_DIR/.." && pwd)"

anomaly_engine_artifacts_dir() {
  printf '%s\n' "${ANOMALY_ENGINE_ARTIFACTS_DIR:-$ENGINE_PROJECT_ROOT/dist/artifacts}"
}

anomaly_crossover_version() {
  printf '%s\n' "${ANOMALY_CROSSOVER_VERSION:-26.3.0}"
}

anomaly_engine_version_label_trim() {
  local ver="$1"
  ver="${ver//$'\r'/}"
  ver="${ver#"${ver%%[![:space:]]*}"}"
  ver="${ver%"${ver##*[![:space:]]}"}"
  printf '%s\n' "$ver"
}

anomaly_format_engine_version_from_wine() {
  local wine_bin="${1:-}"
  local wine_raw wine_ver cx_ver
  local version_label="${ANOMALY_ENGINE_VERSION_LABEL:-}"
  if [[ -n "$version_label" ]]; then
    anomaly_engine_version_label_trim "$version_label"
    return 0
  fi
  if [[ -z "$wine_bin" && -n "${WINE_INSTALL:-}" ]]; then
    wine_bin="$WINE_INSTALL/bin/wine"
  fi
  [[ -x "$wine_bin" ]] || return 1
  wine_raw="$(arch -x86_64 "$wine_bin" --version 2>/dev/null || true)"
  wine_ver="${wine_raw#wine-}"
  cx_ver="$(anomaly_crossover_version)"
  printf 'wine crossover %s (wine %s)\n' "$cx_ver" "$wine_ver"
}

anomaly_detect_engine_version_label() {
  anomaly_format_engine_version_from_wine "${1:-}"
}

anomaly_engine_version_slug_from_label() {
  local label="$1"
  local slug cx wine_ver tail
  label="$(anomaly_engine_version_label_trim "$label")"
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

anomaly_engine_versions_equal() {
  local left right left_slug right_slug
  left="$(anomaly_engine_version_label_trim "${1:-}")"
  right="$(anomaly_engine_version_label_trim "${2:-}")"
  [[ -n "$left" && -n "$right" ]] || return 1
  [[ "$left" == "$right" ]] && return 0
  left_slug="$(anomaly_engine_version_slug_from_label "$left")"
  right_slug="$(anomaly_engine_version_slug_from_label "$right")"
  [[ "$left_slug" == "$right" || "$left" == "$right_slug" || "$left_slug" == "$right_slug" ]]
}

anomaly_read_engine_version_file() {
  local engine_root="$1"
  local ver
  [[ -f "$engine_root/version" ]] || return 1
  ver="$(anomaly_engine_version_label_trim "$(cat "$engine_root/version")")"
  [[ -n "$ver" ]] || return 1
  printf '%s\n' "$ver"
}

anomaly_write_engine_version_file() {
  local engine_root="$1"
  local ver="$2"
  ver="$(anomaly_engine_version_label_trim "$ver")"
  [[ -n "$ver" ]] || return 1
  printf '%s\n' "$ver" >"$engine_root/version"
}

anomaly_engine_version_from_tarball() {
  local tarball="$1"
  local ver
  ver="$(tar -xOf "$tarball" wswine.bundle/version 2>/dev/null | head -1 || true)"
  ver="$(anomaly_engine_version_label_trim "$ver")"
  [[ -n "$ver" ]] || return 1
  printf '%s\n' "$ver"
}

# Archive path for a version label and build number, e.g.
# "CX26-W11-ANOMALY" 19 -> dist/artifacts/CX26-W11-ANOMALY-19.tar.xz. The build
# number comes from config/build-number or --build-number (see
# pack-engine-artifact.sh and docs/building.md, "Versioning").
anomaly_engine_archive_path_for_format() {
  local label="$1"
  local dir="${2:-$(anomaly_engine_artifacts_dir)}"
  local format="${3:-xz}"
  local build_number="$4"
  local ext
  label="$(anomaly_engine_version_label_trim "$label")"
  if [[ ! "$label" =~ ^CX[0-9]+-W[0-9]+-ANOMALY$ ]]; then
    echo "Unsupported engine version label: $label (expected CX<n>-W<n>-ANOMALY)" >&2
    return 1
  fi
  case "$format" in
    zst | zstd) ext="tar.zst" ;;
    xz) ext="tar.xz" ;;
    *)
      echo "Unknown engine archive format: $format" >&2
      return 1
      ;;
  esac
  printf '%s/%s-%s.%s\n' "$dir" "$label" "$build_number" "$ext"
}

anomaly_find_zstd() {
  local candidate
  for candidate in \
    "${ANOMALY_ZSTD:-}" \
    "$ENGINE_PROJECT_ROOT/tools/zstd/zstd" \
    "$(command -v zstd 2>/dev/null || true)"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      printf '%s/%s\n' "$(cd "$(dirname "$candidate")" && pwd -P)" "$(basename "$candidate")"
      return 0
    fi
  done
  return 1
}
