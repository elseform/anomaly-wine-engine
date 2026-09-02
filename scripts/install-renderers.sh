#!/usr/bin/env bash
# Stage the switchable graphics backends into the Wine installation tree.
#
# Layout (mirrors CrossOver's own tree):
#
#   lib/wine/<arch>/     Wine builtins ONLY, plus winemetal.dll / winemetal.so
#                        (winemetal has no Wine counterpart; CX ships it as a
#                        builtin too, and wineboot needs the PE present to
#                        create the system32 fake DLL or DXMT's d3d11 fails
#                        to load with STATUS_DLL_NOT_FOUND)
#   lib/d3dmetal/        Apple GPTK D3DMetal   (x86_64 only)
#   lib/dxmt/            DXMT                  (x86_64 + i386)
#   lib/dxvk/            DXVK                  (x86_64 + i386)
#
# Each backend directory carries its own PE and unix subdirectories, so
# cxcompatdb.so can activate one by prepending a single directory to the DLL
# search path. Backends never overwrite a Wine builtin: with cxcompatdb
# disabled the tree falls back to wined3d instead of a silent d3dmetal/dxmt
# hybrid.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=env-x86_64.sh
source "$SCRIPT_DIR/env-x86_64.sh"

WINE_INSTALL="${1:-$WINE_INSTALL}"
DXMT_SRC="${DXMT_SRC:-$REPO_ROOT/sources/dxmt}"
GPTK_SRC="${GPTK_SRC:-$REPO_ROOT/sources/gptk40b1/d3dmetal}"
DXVK_SRC="${DXVK_SRC:-$REPO_ROOT/sources/dxvk}"
[[ -d "$DXVK_SRC" ]] || DXVK_SRC="${CROSSOVER_DXVK:-}"
WINE_BUILD64="${WINE_BUILD64:-$WINE_SRC/build64}"

[[ -d "$WINE_INSTALL" ]] || {
  echo "Error: Wine install directory not found: $WINE_INSTALL" >&2
  exit 1
}

echo "==> Staging graphics backends into $WINE_INSTALL"

# Modules a backend may provide. winemetal is deliberately absent: it belongs
# in lib/wine as well, so it is never sanitized away.
BACKEND_MODULES=(
  ddraw d3d8 d3d9 d3d10 d3d10_1 d3d10core d3d11 d3d12 dxgi nvapi64 nvngx
)

# ---------------------------------------------------------------------------
# 1. Sanitize lib/wine: undo any backend DLLs a previous run copied over the
#    Wine builtins. Restore the builtin from the build tree when available,
#    otherwise drop the file (module Wine does not ship at all, e.g. nvngx).
# ---------------------------------------------------------------------------
sanitize_wine_dir() {
  local arch="$1"
  local dir="$WINE_INSTALL/lib/wine/$arch"
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

# True when a file of this name exists in one of the backend source trees,
# i.e. it was staged by an earlier run of this script rather than by Wine.
backend_owns() {
  local name="$1" src
  for src in "$GPTK_SRC/wine" "$DXMT_SRC" "$DXVK_SRC"; do
    [[ -n "$src" && -d "$src" ]] || continue
    if find "$src" -maxdepth 2 -type f -name "$name" -print -quit 2>/dev/null | grep -q .; then
      return 0
    fi
  done
  return 1
}

sanitize_wine_dir x86_64-windows
sanitize_wine_dir i386-windows

# D3DMetal's unix bridges are symlinks into lib/external; Wine ships no unix
# libraries for these modules, so any such link is ours to remove.
UNIX_DIR="$WINE_INSTALL/lib/wine/x86_64-unix"
if [[ -d "$UNIX_DIR" ]]; then
  for module in "${BACKEND_MODULES[@]}"; do
    if [[ -L "$UNIX_DIR/$module.so" ]]; then
      rm -f "$UNIX_DIR/$module.so"
      echo "  Removed backend bridge x86_64-unix/$module.so from lib/wine"
    fi
  done
fi

# ---------------------------------------------------------------------------
# 2. DXMT -> lib/dxmt
# ---------------------------------------------------------------------------
if [[ -d "$DXMT_SRC" ]]; then
  echo "--> DXMT from $DXMT_SRC"
  rm -rf "$WINE_INSTALL/lib/dxmt"
  mkdir -p "$WINE_INSTALL/lib/dxmt/x86_64-windows" \
           "$WINE_INSTALL/lib/dxmt/i386-windows" \
           "$WINE_INSTALL/lib/dxmt/x86_64-unix"

  if [[ -f "$DXMT_SRC/x86_64-unix/winemetal.so" ]]; then
    cp "$DXMT_SRC/x86_64-unix/winemetal.so" "$WINE_INSTALL/lib/dxmt/x86_64-unix/"
    # Host bridge also goes to lib/wine: it is loaded by the unix side, which
    # does not follow the PE dll search path.
    cp "$DXMT_SRC/x86_64-unix/winemetal.so" "$WINE_INSTALL/lib/wine/x86_64-unix/"
    echo "  winemetal.so -> lib/dxmt + lib/wine"
  fi

  for arch in x86_64-windows i386-windows; do
    [[ -d "$DXMT_SRC/$arch" ]] || continue
    cp -R "$DXMT_SRC/$arch/"* "$WINE_INSTALL/lib/dxmt/$arch/"
    # winemetal.dll must exist in lib/wine so wineboot registers it.
    if [[ -f "$DXMT_SRC/$arch/winemetal.dll" && -d "$WINE_INSTALL/lib/wine/$arch" ]]; then
      cp "$DXMT_SRC/$arch/winemetal.dll" "$WINE_INSTALL/lib/wine/$arch/"
    fi
    echo "  Staged DXMT $arch"
  done
else
  echo "  Skipping DXMT: $DXMT_SRC not found (run scripts/fetch-dxmt.sh)" >&2
fi

# ---------------------------------------------------------------------------
# 3. D3DMetal (Apple GPTK) -> lib/d3dmetal + lib/external
# ---------------------------------------------------------------------------
if [[ -d "$GPTK_SRC" ]]; then
  echo "--> D3DMetal from $GPTK_SRC"
  mkdir -p "$WINE_INSTALL/lib/external"
  cp -R "$GPTK_SRC/external/"* "$WINE_INSTALL/lib/external/"

  rm -rf "$WINE_INSTALL/lib/d3dmetal"
  mkdir -p "$WINE_INSTALL/lib/d3dmetal/x86_64-windows" \
           "$WINE_INSTALL/lib/d3dmetal/x86_64-unix"
  # d3d10.dll/.so deliberately excluded: GPTK's own D3D10 stub round-trips
  # through the same shared libd3dshared.dylib as d3d11, colliding with it and
  # tripping a __wine_syscall_dispatcher livelock (confirmed: savegame hang
  # under GPTK 4.0b2). scripts/interactive-setup.sh adds a per-app DllOverrides
  # entry pointing d3d10 at Wine's own independent implementation instead of
  # this one. Keep this exclusion in sync with that script's matching one —
  # see docs/d3dmetal-savegame-crash.md.
  for f in "$GPTK_SRC/wine/x86_64-windows/"*; do
    [[ "$(basename "$f")" == "d3d10.dll" ]] && continue
    cp -R "$f" "$WINE_INSTALL/lib/d3dmetal/x86_64-windows/"
  done
  for f in "$GPTK_SRC/wine/x86_64-unix/"*; do
    [[ "$(basename "$f")" == "d3d10.so" ]] && continue
    cp -RP "$f" "$WINE_INSTALL/lib/d3dmetal/x86_64-unix/"
  done
  echo "  Staged D3DMetal x86_64 (no i386 payload exists upstream), d3d10.dll/.so excluded"

  # Compatibility symlinks for Sikarugir / CrossOver legacy paths.
  # lib/apple_gptk must not survive as a real directory from a prior run: `ln -sfn`
  # only replaces an existing symlink in place, but drops the new link *inside* an
  # existing real directory instead, silently breaking the legacy candidate path.
  ln -sfn ../external "$WINE_INSTALL/lib/d3dmetal/external"
  [[ -L "$WINE_INSTALL/lib/apple_gptk" || ! -e "$WINE_INSTALL/lib/apple_gptk" ]] || rm -rf "$WINE_INSTALL/lib/apple_gptk"
  ln -sfn d3dmetal "$WINE_INSTALL/lib/apple_gptk"
  mkdir -p "$WINE_INSTALL/lib64/apple_gptk"
  ln -sfn ../../lib/d3dmetal "$WINE_INSTALL/lib64/apple_gptk/wine"
  ln -sfn ../../lib/external "$WINE_INSTALL/lib64/apple_gptk/external"
else
  echo "  Skipping D3DMetal: $GPTK_SRC not found" >&2
fi

# ---------------------------------------------------------------------------
# 3b. Named GPTK betas -> lib/gptk40b1 + lib/gptk40b2, staged unconditionally
#     (independent of GPTK_SRC above). Lets GAMMA_GRAPHICS_BACKEND select a
#     specific beta directly (gptk40b1 | gptk40b2), no separate version
#     variable, no re-copy on switch — see docs/d3dmetal-savegame-crash.md.
#     Same flat shape as lib/d3dmetal (x86_64-windows/x86_64-unix/external
#     directly inside), which is what cxcompatdb's generic
#     "root/lib/<backend>" fallback for any non-d3dmetal/dxmt backend name
#     already expects with zero extra code.
# ---------------------------------------------------------------------------
stage_gptk_beta() {
  local beta="$1" src="$REPO_ROOT/sources/$1/d3dmetal" dst="$WINE_INSTALL/lib/$1"
  [[ -d "$src/wine" ]] || { echo "  Skipping $beta: $src not found" >&2; return 0; }
  echo "--> $beta from $src"
  rm -rf "$dst"
  mkdir -p "$dst/x86_64-windows" "$dst/x86_64-unix" "$dst/external"
  cp -R "$src/external/"* "$dst/external/"
  for f in "$src/wine/x86_64-windows/"*; do
    [[ "$(basename "$f")" == "d3d10.dll" ]] && continue
    cp -R "$f" "$dst/x86_64-windows/"
  done
  for f in "$src/wine/x86_64-unix/"*; do
    [[ "$(basename "$f")" == "d3d10.so" ]] && continue
    cp -RP "$f" "$dst/x86_64-unix/"
  done
  echo "  Staged $beta -> lib/$beta (d3d10.dll/.so excluded, see docs/d3dmetal-savegame-crash.md)"
}
stage_gptk_beta gptk40b1
stage_gptk_beta gptk40b2

# ---------------------------------------------------------------------------
# 4. DXVK -> lib/dxvk
#    Ships no dxgi.dll: DXVK on CrossOver pairs with Wine's builtin DXGI.
#    Requires a Vulkan-enabled engine (build-wine.sh --with-vulkan) plus
#    libMoltenVK.dylib in the tree; cxcompatdb refuses to activate otherwise.
# ---------------------------------------------------------------------------
if [[ -n "$DXVK_SRC" && -d "$DXVK_SRC" ]]; then
  echo "--> DXVK from $DXVK_SRC"
  rm -rf "$WINE_INSTALL/lib/dxvk"
  for arch in x86_64-windows i386-windows; do
    [[ -d "$DXVK_SRC/$arch" ]] || continue
    mkdir -p "$WINE_INSTALL/lib/dxvk/$arch"
    cp -R "$DXVK_SRC/$arch/"*.dll "$WINE_INSTALL/lib/dxvk/$arch/"
    echo "  Staged DXVK $arch"
  done
  if [[ ! -f "$WINE_INSTALL/lib/wine/x86_64-unix/libMoltenVK.dylib" &&
        ! -f "$WINE_INSTALL/lib64/libMoltenVK.dylib" ]]; then
    echo "  Note: no libMoltenVK.dylib in the engine tree yet — DXVK stays inactive" >&2
    echo "        until the engine is built with --with-vulkan --vulkan-source crossover" >&2
  fi
else
  echo "  Skipping DXVK: no source (set DXVK_SRC, or install CrossOver.app)" >&2
fi

echo "==> Backends staged."
