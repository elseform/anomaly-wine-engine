#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WINEPREFIX="${1:?usage: install.sh <WINEPREFIX> [x86_64|i386|both]}"
ARCH="${2:-x86_64}"

install_one() {
  local sysdir="$1" shim="$2"
  local real="$sysdir/d3dx11_43.dll"
  local orig="$sysdir/d3dx11_43_orig.dll"

  [[ -f "$real" ]] || { echo "  Skip $sysdir: no d3dx11_43.dll present" >&2; return 0; }

  if [[ ! -f "$orig" ]]; then
    cp "$real" "$orig"
    echo "  Backed up real DLL -> $orig"
  else
    echo "  $orig already exists, leaving it (assumed already installed)"
  fi

  cp "$shim" "$real"
  echo "  Installed shim -> $real"
}

if [[ "$ARCH" == "x86_64" || "$ARCH" == "both" ]]; then
  echo "==> x86_64 (system32)"
  install_one "$WINEPREFIX/drive_c/windows/system32" "$SCRIPT_DIR/build/x86_64/d3dx11_43.dll"
fi

if [[ "$ARCH" == "i386" || "$ARCH" == "both" ]]; then
  echo "==> i386 (syswow64)"
  install_one "$WINEPREFIX/drive_c/windows/syswow64" "$SCRIPT_DIR/build/i386/d3dx11_43.dll"
fi

echo "Done."
