#!/usr/bin/env bash
# Apply patches/series to the extracted Wine source tree.
#
#   apply-wine-series.sh [--src DIR] [--with-vulkan] [--dry-run]
#
# Patches apply in series order with `patch -p1 -F0` (no fuzz). Every applied
# patch is recorded with its sha256 in DIR/.anomaly-series, so a re-run skips
# what is already there and applies only patches appended to the series since.
# A recorded patch whose name, content or position no longer matches the series
# is fatal: the tree then has to be extracted again
# (`prepare-build-deps.sh --force`).
#
# After patching, configure is regenerated from configure.ac with autoconf,
# because the CrossOver port changes configure.ac.
#
# The series and the "patches" list in config/engine-release.json must name
# the same patches in the same order.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env-x86_64.sh
source "$SCRIPT_DIR/env-x86_64.sh"

SRC="$WINE_SRC"
WITH_VULKAN=0
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --src)
      SRC="${2:-}"
      [[ -n "$SRC" ]] || { echo "Missing value for --src" >&2; exit 1; }
      shift 2
      ;;
    --with-vulkan) WITH_VULKAN=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h | --help)
      sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

PATCHES_DIR="$OGOM/patches"
SERIES="$PATCHES_DIR/series"
STAMP="$SRC/.anomaly-series"
RELEASE_CONFIG="$OGOM/config/engine-release.json"

[[ -f "$SERIES" ]] || { echo "Missing $SERIES" >&2; exit 1; }
[[ -f "$SRC/configure.ac" ]] || {
  echo "No Wine source tree at $SRC; run prepare-build-deps.sh first." >&2
  exit 1
}

# name<TAB>mode for every series entry, comments and blank lines dropped.
series_entries() {
  sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$SERIES" | awk 'NF { print $1 "\t" ($2 == "" ? "always" : $2) }'
}

# The release metadata records the same list (all entries, in order).
series_names="$(series_entries | cut -f1)"
config_names="$(python3 -c 'import json, sys; print("\n".join(json.load(open(sys.argv[1]))["patches"]))' "$RELEASE_CONFIG")"
if [[ "$series_names" != "$config_names" ]]; then
  echo "patches/series and the \"patches\" list in $RELEASE_CONFIG differ:" >&2
  diff <(printf '%s\n' "$series_names") <(printf '%s\n' "$config_names") >&2 || true
  exit 1
fi

recorded=()
if [[ -f "$STAMP" ]]; then
  while IFS= read -r line; do
    [[ -n "$line" ]] && recorded+=("$line")
  done <"$STAMP"
fi

index=0
applied=0
while IFS=$'\t' read -r name mode; do
  case "$mode" in
    always) ;;
    without-vulkan) [[ "$WITH_VULKAN" -eq 0 ]] || continue ;;
    *)
      echo "Unknown mode '$mode' for $name in $SERIES" >&2
      exit 1
      ;;
  esac
  file="$PATCHES_DIR/$name"
  [[ -f "$file" ]] || { echo "Missing patch file: $file" >&2; exit 1; }
  entry="$name $(shasum -a 256 "$file" | awk '{print $1}')"

  if [[ $index -lt ${#recorded[@]} ]]; then
    if [[ "${recorded[$index]}" != "$entry" ]]; then
      echo "$SRC was patched with a different series at entry $((index + 1)):" >&2
      echo "  tree:   ${recorded[$index]}" >&2
      echo "  series: $entry" >&2
      echo "Extract a fresh tree: scripts/prepare-build-deps.sh --force" >&2
      exit 1
    fi
    index=$((index + 1))
    continue
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "+ patch -p1 -F0 -d $SRC < patches/$name"
  else
    if ! patch --forward --batch -s -p1 -F0 --no-backup-if-mismatch -d "$SRC" <"$file"; then
      echo "Cannot apply $name to $SRC" >&2
      exit 1
    fi
    printf '%s\n' "$entry" >>"$STAMP"
    echo "Applied $name"
  fi
  applied=$((applied + 1))
  index=$((index + 1))
done < <(series_entries)

if [[ $index -lt ${#recorded[@]} ]]; then
  echo "$SRC carries patches that are no longer in the series:" >&2
  printf '  %s\n' "${recorded[@]:$index}" >&2
  echo "Extract a fresh tree: scripts/prepare-build-deps.sh --force" >&2
  exit 1
fi

if [[ "$applied" -eq 0 && "$SRC/configure" -nt "$SRC/configure.ac" ]]; then
  echo "Wine series already applied ($index patches); configure is current"
  exit 0
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "+ autoconf -o configure configure.ac (in $SRC)"
  exit 0
fi
AUTOCONF="$HOMEBREW_PREFIX/bin/autoconf"
[[ -x "$AUTOCONF" ]] || {
  echo "Missing $AUTOCONF; run scripts/build-wine.sh --install-deps" >&2
  exit 1
}
(cd "$SRC" && PATH="$HOMEBREW_PREFIX/bin:/usr/bin:/bin" "$AUTOCONF" -o configure configure.ac)
rm -rf "$SRC/autom4te.cache" "$SRC/configure~"
echo "Regenerated configure ($("$AUTOCONF" --version | head -n 1))"
