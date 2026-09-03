#!/usr/bin/env bash
set -euo pipefail

ENGINE_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_PROJECT_ROOT="$(cd "$ENGINE_COMMON_DIR/.." && pwd)"

gamma_engine_artifacts_dir() {
  printf '%s\n' "${GAMMA_ENGINE_ARTIFACTS_DIR:-${CYDER_ENGINE_ARTIFACTS_DIR:-$ENGINE_PROJECT_ROOT/dist/artifacts}}"
}

gamma_crossover_version() {
  printf '%s\n' "${GAMMA_CROSSOVER_VERSION:-${CYDER_CROSSOVER_VERSION:-26.3.0}}"
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
  local version_label="${GAMMA_ENGINE_VERSION_LABEL:-${CYDER_ENGINE_VERSION_LABEL:-}}"
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

# Compact basename derived mechanically from a version label, e.g.
# "CX26.3.0-W11-Gamma086" -> "CX26W11-Gamma086". This used to be a separate,
# hand-typed field (artifactBasename in engine-release.json) that had to be
# kept in sync with versionLabel/engine-version.txt by hand and could drift;
# it is now always computed from the label, so there is exactly one place a
# version number is typed. See docs/versioning-policy.md.
gamma_engine_artifact_basename_from_label() {
  local label
  label="$(gamma_engine_version_label_trim "${1:-}")"
  if [[ "$label" =~ ^CX([0-9]+)(\.[0-9]+)*-W([0-9]+)-Gamma([0-9]+)$ ]]; then
    printf 'CX%sW%s-Gamma%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"
    return 0
  fi
  return 1
}

# Artifact basename stem (no extension or sequence) for a version label.
gamma_engine_artifact_basename() {
  local label="${1:-}"
  local name=""
  if [[ -z "$label" ]]; then
    label="${GAMMA_ENGINE_VERSION_LABEL:-${CYDER_ENGINE_VERSION_LABEL:-}}"
  fi
  if [[ -z "$label" && -f "$ENGINE_PROJECT_ROOT/config/engine-version.txt" ]]; then
    label="$(head -n 1 "$ENGINE_PROJECT_ROOT/config/engine-version.txt" 2>/dev/null || true)"
  fi
  [[ -n "$label" ]] && name="$(gamma_engine_artifact_basename_from_label "$label" 2>/dev/null || true)"
  printf '%s\n' "$name"
}

# Next numbered artifact basename. Sequence is per canonical version label and
# considers legacy names without the dash before Gamma so migration continues
# from the highest existing pack number.
gamma_engine_artifact_next_basename() {
  local label="${1:-}"
  local dir="${2:-$(gamma_engine_artifacts_dir)}"
  local base legacy_base path name suffix max=0 nullglob_was_set=0
  base="$(gamma_engine_artifact_basename "$label")"
  [[ -n "$base" ]] || return 1
  legacy_base="${base/-Gamma/Gamma}"

  if [[ -d "$dir" ]]; then
    shopt -q nullglob && nullglob_was_set=1
    shopt -s nullglob
    for path in \
      "$dir/$base"-*.tar.zst "$dir/$base"-*.tar.xz \
      "$dir/$legacy_base"-*.tar.zst "$dir/$legacy_base"-*.tar.xz; do
      name="${path##*/}"
      suffix="${name#"$base"-}"
      [[ "$suffix" != "$name" ]] || suffix="${name#"$legacy_base"-}"
      suffix="${suffix%.tar.zst}"
      suffix="${suffix%.tar.xz}"
      if [[ "$suffix" =~ ^[0-9]+$ ]] && (( 10#$suffix > max )); then
        max=$((10#$suffix))
      fi
    done
    (( nullglob_was_set )) || shopt -u nullglob
  fi
  printf '%s-%d\n' "$base" "$((max + 1))"
}

gamma_engine_archive_path_for_format() {
  local ver="$1"
  local dir="${2:-$(gamma_engine_artifacts_dir)}"
  local format="${3:-zst}"
  local base
  base="$(gamma_engine_artifact_next_basename "$ver" "$dir" 2>/dev/null || true)"
  if [[ -n "$base" ]]; then
    case "$format" in
      zst | zstd) printf '%s/%s.tar.zst\n' "$dir" "$base" ; return 0 ;;
      xz) printf '%s/%s.tar.xz\n' "$dir" "$base" ; return 0 ;;
    esac
  fi
  case "$format" in
    zst | zstd) printf '%s/engine-%s.tar.zst\n' "$dir" "$ver" ;;
    xz) printf '%s/gamma-wine-x86_64-%s.tar.xz\n' "$dir" "$ver" ;;
    *)
      echo "Unknown engine archive format: $format" >&2
      return 1
      ;;
  esac
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
