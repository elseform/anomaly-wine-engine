#!/usr/bin/env bash
# Stage the two user-selectable graphics backends using CrossOver's layout:
#
#   lib/wine/<arch>/             Wine builtins; winemetal.dll also lives here
#   lib/dxmt/                    DXMT (x86_64 only; no 32-bit games targeted)
#   lib64/apple_gptk/wine/       Apple D3DMetal GPTK 4.0b2 (x86_64)
#   lib64/apple_gptk/external/   D3DMetal host libraries and framework
#
# wined3d remains untouched in lib/wine and is used only when cxcompatdb
# rejects the selected backend. DXVK and alternate GPTK payloads are not
# shipped.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=env-x86_64.sh
source "$SCRIPT_DIR/env-x86_64.sh"

WINE_INSTALL="${1:-$WINE_INSTALL}"
DXMT_SRC="${DXMT_SRC:-$REPO_ROOT/renderers/dxmt}"
GPTK_SRC="${GPTK_SRC:-$REPO_ROOT/renderers/gptk40b2/d3dmetal}"
WINE_BUILD64="${WINE_BUILD64:-$WINE_SRC/build64}"

[[ -d "$WINE_INSTALL" ]] || {
  echo "Error: Wine install directory not found: $WINE_INSTALL" >&2
  exit 1
}
[[ -d "$DXMT_SRC/x86_64-windows" ]] || {
  echo "Error: DXMT source not found: $DXMT_SRC (run scripts/fetch-dxmt.sh)" >&2
  exit 1
}
[[ -d "$GPTK_SRC/wine/x86_64-windows" && -d "$GPTK_SRC/external" ]] || {
  echo "Error: GPTK 4.0b2 source not found: $GPTK_SRC" >&2
  exit 1
}

echo "==> Staging graphics backends into $WINE_INSTALL"

BACKEND_MODULES=(
  ddraw d3d8 d3d9 d3d10 d3d10_1 d3d10core d3d11 d3d12 dxgi
  nvapi64 nvngx nvngx-on-metalfx atidxx64
)

backend_owns() {
  local name="$1" src
  for src in "$GPTK_SRC/wine" "$DXMT_SRC"; do
    if find "$src" -maxdepth 2 -type f -name "$name" -print -quit 2>/dev/null | grep -q .; then
      return 0
    fi
  done
  return 1
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

echo "--> D3DMetal GPTK 4.0b2 from $GPTK_SRC"
GPTK_DST="$WINE_INSTALL/lib64/apple_gptk"
mkdir -p "$GPTK_DST/wine/x86_64-windows" \
         "$GPTK_DST/wine/x86_64-unix" \
         "$GPTK_DST/external"
cp -R "$GPTK_SRC/external/." "$GPTK_DST/external/"

# GPTK's d3d10 bridge is excluded because it shares libd3dshared state with
# d3d11 and caused a confirmed savegame hang. Wine's builtin d3d10 remains.
for file in "$GPTK_SRC/wine/x86_64-windows/"*; do
  [[ "$(basename "$file")" == "d3d10.dll" ]] && continue
  cp -R "$file" "$GPTK_DST/wine/x86_64-windows/"
done
for file in "$GPTK_SRC/wine/x86_64-unix/"*; do
  [[ "$(basename "$file")" == "d3d10.so" ]] && continue
  cp -RP "$file" "$GPTK_DST/wine/x86_64-unix/"
done

echo "  Staged GPTK 4.0b2 in lib64/apple_gptk"
echo "==> Backends staged: d3dmetal, dxmt (wined3d fallback remains built in)."
