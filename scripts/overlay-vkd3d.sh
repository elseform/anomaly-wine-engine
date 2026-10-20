#!/usr/bin/env bash
# Overlay the shader compiler of a pinned vkd3d fork onto Wine's vendored libs/vkd3d.
#
#   overlay-vkd3d.sh [--src DIR] [--dry-run]
#
# Runs after apply-wine-series.sh and before configure/make. Only the HLSL
# shader compiler side is replaced (libs/vkd3d-shader, its private headers and
# include/vkd3d_shader.h); Wine's D3D12 layer, blob and debug code stay as they
# are. The fork is pinned in config/engine-release.json under "vkd3d"
# (commit and the sha256 of its `git archive --format=tar` output).
#
# The fork source is a local git checkout named by ANOMALY_VKD3D_SOURCE. The
# archive is cached in build/cache/vkd3d/<commit>.tar; every run verifies the
# cached archive against the pinned sha256, and any mismatch is fatal. Without
# a cached archive the checkout must contain the pinned commit.
#
# The fork builds standalone with its own Windows headers; Wine's build uses
# its own, so the overlay rewrites the include names of the copied files
# (vkd3d_windows.h -> windows.h, vkd3d_d3dcommon.h -> d3dcommon.h, ...) and the
# one source name that changed (utf8.c -> string.c). Re-running with the same
# pin does nothing; a changed pin overlays again.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC=""
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --src)
      SRC="${2:-}"
      [[ -n "$SRC" ]] || { echo "Missing value for --src" >&2; exit 1; }
      shift 2
      ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h | --help)
      sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# shellcheck source=env.sh
source "$SCRIPT_DIR/env.sh"
SRC="${SRC:-$WINE_SRC}"

RELEASE_CONFIG="$OGOM/config/engine-release.json"
CACHE_ROOT="${ANOMALY_VKD3D_CACHE:-$OGOM/build/cache/vkd3d}"
VKD3D_DIR="$SRC/libs/vkd3d"
STAMP="$SRC/.anomaly-vkd3d-overlay"

COMMIT="$(/usr/bin/python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["vkd3d"]["commit"])' "$RELEASE_CONFIG")"
PIN_SHA="$(/usr/bin/python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["vkd3d"]["archiveSHA256"])' "$RELEASE_CONFIG")"
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ && "$PIN_SHA" =~ ^[0-9a-f]{64}$ ]] || {
  echo "config/engine-release.json needs vkd3d.commit (40 hex) and vkd3d.archiveSHA256 (64 hex)" >&2
  exit 1
}

if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$COMMIT $PIN_SHA" ]]; then
  echo "vkd3d overlay ${COMMIT:0:12} already applied"
  exit 0
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "+ overlay vkd3d fork ${COMMIT:0:12} (archive sha256 ${PIN_SHA:0:12}) onto $VKD3D_DIR"
  exit 0
fi

[[ -f "$VKD3D_DIR/Makefile.in" ]] || {
  echo "No Wine source tree at $SRC; run prepare-build-deps.sh first." >&2
  exit 1
}

ARCHIVE="$CACHE_ROOT/$COMMIT.tar"
if [[ ! -f "$ARCHIVE" ]]; then
  FORK="${ANOMALY_VKD3D_SOURCE:-}"
  [[ -n "$FORK" ]] || {
    echo "No cached vkd3d archive for ${COMMIT:0:12}; set ANOMALY_VKD3D_SOURCE to a checkout of the fork." >&2
    exit 1
  }
  git -C "$FORK" cat-file -e "$COMMIT^{commit}" 2>/dev/null || {
    echo "$FORK does not contain the pinned vkd3d commit $COMMIT" >&2
    exit 1
  }
  mkdir -p "$CACHE_ROOT"
  git -C "$FORK" archive --format=tar -o "$ARCHIVE.part" "$COMMIT"
  mv "$ARCHIVE.part" "$ARCHIVE"
fi
ACTUAL_SHA="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
[[ "$ACTUAL_SHA" == "$PIN_SHA" ]] || {
  echo "vkd3d archive checksum mismatch ($ACTUAL_SHA, pinned $PIN_SHA)." >&2
  echo "Delete $ARCHIVE to rebuild it from the fork checkout, or update the pin." >&2
  exit 1
}

FORK_TREE="$CACHE_ROOT/$COMMIT"
rm -rf "$FORK_TREE"
mkdir -p "$FORK_TREE"
tar -xf "$ARCHIVE" -C "$FORK_TREE"

# Copy the fork's shader compiler over Wine's. Only the sources and private
# headers the compiler needs are taken; make_spirv, version maps and pkg-config
# templates belong to the fork's standalone build.
rm -rf "$VKD3D_DIR/libs/vkd3d-shader"
mkdir -p "$VKD3D_DIR/libs/vkd3d-shader"
for ext in c h l y; do
  for f in "$FORK_TREE"/libs/vkd3d-shader/*."$ext"; do
    cp "$f" "$VKD3D_DIR/libs/vkd3d-shader/"
  done
done
cp "$FORK_TREE/libs/vkd3d-common/string.c" "$VKD3D_DIR/libs/vkd3d-common/string.c"
rm -f "$VKD3D_DIR/libs/vkd3d-common/utf8.c"
# Wine's D3D12 layer still includes the old header name; the fork renamed it.
printf '%s\n' '/* Forwarding header: the vkd3d fork renamed vkd3d_utf8.h to vkd3d_string.h. */' \
  '#include "vkd3d_string.h"' >"$VKD3D_DIR/include/private/vkd3d_utf8.h"
cp "$FORK_TREE/include/vkd3d_shader.h" "$VKD3D_DIR/include/vkd3d_shader.h"
for h in vkd3d_common.h vkd3d_string.h; do
  cp "$FORK_TREE/include/private/$h" "$VKD3D_DIR/include/private/$h"
done

# The fork's header names to Wine's.
REWRITE=(
  -e 's|"vkd3d_windows\.h"|"windows.h"|'
  -e 's|"vkd3d_d3dcommon\.h"|"d3dcommon.h"|'
  -e 's|"vkd3d_d3dx9shader\.h"|"d3dx9shader.h"|'
  -e 's|"vkd3d_d3d12shader\.h"|"d3d12shader.h"|'
  -e 's|"rbtree\.h"|"wine/rbtree.h"|'
  -e 's|"list\.h"|"wine/list.h"|'
)
for f in "$VKD3D_DIR"/libs/vkd3d-shader/*.[chly] "$VKD3D_DIR/libs/vkd3d-common/string.c" \
  "$VKD3D_DIR/include/vkd3d_shader.h" "$VKD3D_DIR/include/private/vkd3d_common.h" \
  "$VKD3D_DIR/include/private/vkd3d_string.h"; do
  sed -i '' "${REWRITE[@]}" "$f"
done

# Wine's Makefile.in names utf8.c; the fork's replacement is string.c.
sed -i '' 's|libs/vkd3d-common/utf8\.c|libs/vkd3d-common/string.c|' "$VKD3D_DIR/Makefile.in"
grep -q 'libs/vkd3d-common/string\.c' "$VKD3D_DIR/Makefile.in" || {
  echo "Could not point $VKD3D_DIR/Makefile.in at string.c" >&2
  exit 1
}

rm -rf "$FORK_TREE"
printf '%s %s' "$COMMIT" "$PIN_SHA" >"$STAMP"
echo "Overlaid vkd3d fork ${COMMIT:0:12} onto $VKD3D_DIR"
