#!/usr/bin/env bash
# Stage the two user-selectable graphics backends using CrossOver's layout:
#
#   lib/wine/<arch>/             Wine builtins; winemetal.dll also lives here
#   lib/dxmt/                    DXMT (x86_64 only; no 32-bit games targeted)
#   lib64/apple_gptk/wine/       Apple D3DMetal GPTK (x86_64), full upstream payload
#   lib64/apple_gptk/external/   D3DMetal host libraries and framework
#
# wined3d remains untouched in lib/wine and is used only when cxcompatdb
# rejects the selected backend. DXVK is not shipped. GPTK is optional and
# user-supplied (Apple's own EULA-restricted GPTK, not bundled in this repo):
# if no payload is found at GPTK_SRC (default renderers/gptk40b2/d3dmetal) or
# via --apple-gptk, D3DMetal staging is skipped and only DXMT is staged. See
# docs/renderers.md for how to supply your own GPTK payload.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=env-x86_64.sh
source "$SCRIPT_DIR/env-x86_64.sh"

WINE_INSTALL="${WINE_INSTALL:-}"
APPLE_GPTK_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apple-gptk)
      [[ $# -ge 2 ]] || { echo "Error: --apple-gptk requires a path" >&2; exit 1; }
      APPLE_GPTK_ARG="$2"
      shift 2
      ;;
    --apple-gptk=*)
      APPLE_GPTK_ARG="${1#*=}"
      shift
      ;;
    *)
      WINE_INSTALL="$1"
      shift
      ;;
  esac
done

DXMT_SRC="${DXMT_SRC:-$REPO_ROOT/renderers/dxmt}"

# --apple-gptk accepts either a version root (e.g. renderers/gptk40b1,
# renderers/gptk40b2 — containing a d3dmetal/ subdir) or a d3dmetal payload
# directory directly (containing wine/ and external/ themselves). GPTK_SRC
# env var still works as a lower-priority override for scripting.
if [[ -n "$APPLE_GPTK_ARG" ]]; then
  if [[ -d "$APPLE_GPTK_ARG/d3dmetal" ]]; then
    GPTK_SRC="$APPLE_GPTK_ARG/d3dmetal"
  else
    GPTK_SRC="$APPLE_GPTK_ARG"
  fi
else
  GPTK_SRC="${GPTK_SRC:-$REPO_ROOT/renderers/gptk40b2/d3dmetal}"
fi

WINE_BUILD64="${WINE_BUILD64:-$WINE_SRC/build64}"

[[ -d "$WINE_INSTALL" ]] || {
  echo "Error: Wine install directory not found: $WINE_INSTALL" >&2
  exit 1
}
[[ -d "$DXMT_SRC/x86_64-windows" ]] || {
  echo "Error: DXMT source not found: $DXMT_SRC (run scripts/fetch-dxmt.sh)" >&2
  exit 1
}
GPTK_AVAILABLE=1
if [[ ! -d "$GPTK_SRC/wine/x86_64-windows" || ! -d "$GPTK_SRC/external" ]]; then
  GPTK_AVAILABLE=0
  echo "==> No GPTK payload at $GPTK_SRC — skipping D3DMetal staging (DXMT only)."
  echo "    D3DMetal is a user-supplied, optional backend: point --apple-gptk or"
  echo "    GPTK_SRC at your own GPTK payload (see docs/renderers.md) to include it."
fi

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

if [[ "$GPTK_AVAILABLE" -eq 1 ]]; then
  # Label for log output only — derived from the resolved path so it reflects
  # whichever payload --apple-gptk/GPTK_SRC actually picked (gptk40b1,
  # gptk40b2, or an arbitrary path), instead of naming one version in the
  # messages while another is what actually gets staged.
  GPTK_LABEL="$(basename "$(dirname "$GPTK_SRC")")"
  [[ "$GPTK_LABEL" == "d3dmetal" ]] && GPTK_LABEL="$(basename "$GPTK_SRC")"

  echo "--> D3DMetal GPTK ($GPTK_LABEL) from $GPTK_SRC"
  GPTK_DST="$WINE_INSTALL/lib64/apple_gptk"
  mkdir -p "$GPTK_DST/wine/x86_64-windows" \
           "$GPTK_DST/wine/x86_64-unix" \
           "$GPTK_DST/external"
  cp -R "$GPTK_SRC/external/." "$GPTK_DST/external/"

  # Full upstream payload, no per-module exclusion. GPTK's own d3d10 bridge
  # previously caused a confirmed savegame hang sharing libd3dshared state with
  # d3d11 (see docs/renderers.md) — comparing GPTK payloads wholesale via
  # --apple-gptk is now how that gets re-tested, not a file-level carve-out.
  cp -R "$GPTK_SRC/wine/x86_64-windows/." "$GPTK_DST/wine/x86_64-windows/"
  cp -RP "$GPTK_SRC/wine/x86_64-unix/." "$GPTK_DST/wine/x86_64-unix/"

  # GPTK ships its NGX/DLSS shim only as nvngx-on-metalfx — there is no
  # separate plain nvngx module to collide with. Renamed to nvngx here (source
  # payload untouched) so Wine's own builtin resolution finds it under the
  # name games actually probe for; cxcompatdb's graphics_modules[] already
  # lists "nvngx" for exactly this. The launcher additionally copies it (as
  # nvngx.dll, alongside nvapi64.dll) into the prefix's system32 when
  # D3DM_ENABLE_METALFX=1 — see interactive_setup.py.
  if [[ -f "$GPTK_DST/wine/x86_64-windows/nvngx-on-metalfx.dll" ]]; then
    mv "$GPTK_DST/wine/x86_64-windows/nvngx-on-metalfx.dll" "$GPTK_DST/wine/x86_64-windows/nvngx.dll"
  fi
  if [[ -f "$GPTK_DST/wine/x86_64-unix/nvngx-on-metalfx.so" ]]; then
    mv "$GPTK_DST/wine/x86_64-unix/nvngx-on-metalfx.so" "$GPTK_DST/wine/x86_64-unix/nvngx.so"
  fi

  # Flag file read by pack-engine-artifact.sh (gamma_engine_gptk_version in
  # engine-common.sh) so the packed artifact's filename records which GPTK
  # payload got staged. Rewritten every run, matching the rest of this
  # directory's wholesale-replace treatment.
  printf '%s\n' "$GPTK_LABEL" >"$GPTK_DST/gptk-version.txt"

  echo "  Staged GPTK ($GPTK_LABEL) in lib64/apple_gptk"
  echo "==> Backends staged: d3dmetal, dxmt. wined3d.dll still ships (manual DllOverrides"
  echo "    only) — cxcompatdb no longer falls back to it automatically on failure."
else
  echo "==> Backend staged: dxmt only. wined3d.dll still ships (manual DllOverrides"
  echo "    only) — cxcompatdb no longer falls back to it automatically on failure."
fi
