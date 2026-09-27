#!/usr/bin/env bash
# Stage the DXMT graphics backend using CrossOver's layout:
#
#   lib/wine/<arch>/             Wine builtins; winemetal.dll also lives here
#   lib/dxmt/                    DXMT (x86_64 only; no 32-bit games targeted)
#
# wined3d remains untouched in lib/wine but is never a fallback: cxcompatdb
# terminates the process when DXMT fails validation. DXVK and D3DMetal are
# not shipped.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=env-x86_64.sh
source "$SCRIPT_DIR/env-x86_64.sh"

WINE_INSTALL="${1:-${WINE_INSTALL:-}}"
DXMT_SRC="${DXMT_SRC:-$REPO_ROOT/renderers/dxmt}"

WINE_BUILD64="${WINE_BUILD64:-$WINE_SRC/build64}"

[[ -d "$WINE_INSTALL" ]] || {
  echo "Error: Wine install directory not found: $WINE_INSTALL" >&2
  exit 1
}
[[ -d "$DXMT_SRC/x86_64-windows" ]] || {
  echo "Error: DXMT source not found: $DXMT_SRC (run scripts/fetch-dxmt.sh)" >&2
  exit 1
}
echo "==> Staging DXMT into $WINE_INSTALL"

BACKEND_MODULES=(
  ddraw d3d8 d3d9 d3d10 d3d10_1 d3d10core d3d11 d3d12 dxgi
  nvapi64 nvngx atidxx64
)

backend_owns() {
  local name="$1"
  find "$DXMT_SRC" -maxdepth 2 -type f -name "$name" -print -quit 2>/dev/null | grep -q .
}

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
    elif backend_owns "$module.dll"; then
      rm -f "$target"
      echo "  Removed backend-only $arch/$module.dll from lib/wine"
    fi
  done
}

sanitize_wine_dir x86_64-windows
sanitize_wine_dir i386-windows

# Remove layouts produced by older builds. These paths are generated engine
# content, never source payloads.
rm -rf "$WINE_INSTALL/lib/d3dmetal" \
       "$WINE_INSTALL/lib/dxvk" \
       "$WINE_INSTALL/lib/external" \
       "$WINE_INSTALL/lib/gptk40b1" \
       "$WINE_INSTALL/lib/gptk40b2" \
       "$WINE_INSTALL/lib/apple_gptk" \
       "$WINE_INSTALL/lib64/apple_gptk"
rm -f "$WINE_INSTALL/lib/wine/x86_64-unix/winemetal.so"
# DXMT is x86_64-only; an i386 winemetal.dll left by an early build would
# otherwise ship forever.
rm -f "$WINE_INSTALL/lib/wine/i386-windows/winemetal.dll"

echo "--> DXMT from $DXMT_SRC"
rm -rf "$WINE_INSTALL/lib/dxmt"
mkdir -p "$WINE_INSTALL/lib/dxmt/x86_64-windows" \
         "$WINE_INSTALL/lib/dxmt/x86_64-unix"

cp -R "$DXMT_SRC/x86_64-windows/." "$WINE_INSTALL/lib/dxmt/x86_64-windows/"
if [[ -f "$DXMT_SRC/x86_64-windows/winemetal.dll" && -d "$WINE_INSTALL/lib/wine/x86_64-windows" ]]; then
  cp "$DXMT_SRC/x86_64-windows/winemetal.dll" "$WINE_INSTALL/lib/wine/x86_64-windows/"
fi
echo "  Staged DXMT x86_64-windows"
cp "$DXMT_SRC/x86_64-unix/winemetal.so" "$WINE_INSTALL/lib/dxmt/x86_64-unix/"

echo "==> Backend staged: dxmt. wined3d.dll still ships (manual DllOverrides"
echo "    only) — cxcompatdb never falls back to it."
