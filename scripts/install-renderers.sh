#!/usr/bin/env bash
# Keep graphics-backend files out of the Wine install tree.
#
# DXMT is not staged here: pack-engine-artifact.sh takes it from a verified
# elseform/dxmt release (scripts/fetch-dxmt-release.sh) and puts it into the
# archive's lib/dxmt, plus the winemetal.dll copy in lib/wine/x86_64-windows.
# This script only makes sure the install tree carries Wine's own Direct3D
# builtins, and none of DXMT's or older layouts' files, so nothing stale can
# reach an archive.
#
# wined3d remains untouched in lib/wine but is never a fallback: cxcompatdb
# terminates the process when DXMT fails validation. DXVK and D3DMetal are
# not shipped.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env-x86_64.sh
source "$SCRIPT_DIR/env-x86_64.sh"

WINE_INSTALL="${1:-${WINE_INSTALL:-}}"
WINE_BUILD64="${WINE_BUILD64:-$WINE_SRC/build64}"

[[ -d "$WINE_INSTALL" ]] || {
  echo "Error: Wine install directory not found: $WINE_INSTALL" >&2
  exit 1
}
echo "==> Cleaning graphics-backend files from $WINE_INSTALL"

BACKEND_MODULES=(
  ddraw d3d8 d3d9 d3d10 d3d10_1 d3d10core d3d11 d3d12 dxgi
  nvapi64 nvngx atidxx64
)
# Modules DXMT provides. A copy in lib/wine that Wine did not build itself is
# a leftover from an older staging layout.
DXMT_MODULES=" d3d10core d3d11 d3d12 dxgi nvapi64 nvngx winemetal "

sanitize_wine_dir() {
  local arch="$1" dir="$WINE_INSTALL/lib/wine/$1"
  local module builtin target
  [[ -d "$dir" ]] || return 0
  for module in "${BACKEND_MODULES[@]}"; do
    target="$dir/$module.dll"
    [[ -f "$target" ]] || continue
    builtin=""
    if [[ -d "$WINE_BUILD64" ]]; then
      builtin="$(find "$WINE_BUILD64/dlls" -maxdepth 3 -type f \
        -path "*/$arch/$module.dll" -print -quit 2>/dev/null || true)"
    fi
    if [[ -n "$builtin" ]]; then
      if ! cmp -s "$builtin" "$target"; then
        cp "$builtin" "$target"
        echo "  Restored Wine builtin $arch/$module.dll"
      fi
    elif [[ "$DXMT_MODULES" == *" $module "* ]]; then
      rm -f "$target"
      echo "  Removed backend-only $arch/$module.dll from lib/wine"
    fi
  done
}

sanitize_wine_dir x86_64-windows
sanitize_wine_dir i386-windows

# Remove backend layouts. These paths are generated engine content, never
# source payloads; packing adds DXMT to the archive itself.
rm -rf "$WINE_INSTALL/lib/dxmt" \
       "$WINE_INSTALL/lib/d3dmetal" \
       "$WINE_INSTALL/lib/dxvk" \
       "$WINE_INSTALL/lib/external" \
       "$WINE_INSTALL/lib/gptk40b1" \
       "$WINE_INSTALL/lib/gptk40b2" \
       "$WINE_INSTALL/lib/apple_gptk" \
       "$WINE_INSTALL/lib64/apple_gptk"
rm -f "$WINE_INSTALL/lib/wine/x86_64-unix/winemetal.so" \
      "$WINE_INSTALL/lib/wine/x86_64-windows/winemetal.dll" \
      "$WINE_INSTALL/lib/wine/i386-windows/winemetal.dll"

echo "==> Install tree clean; DXMT is added at pack time"
