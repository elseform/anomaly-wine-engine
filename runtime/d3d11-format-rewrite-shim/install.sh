#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="${1:?usage: install.sh <engine-root-containing-lib/d3dmetal>}"

D3DMETAL_DIR="$ENGINE_DIR/lib/d3dmetal/x86_64-windows"
[[ -d "$D3DMETAL_DIR" ]] || { echo "No such dir: $D3DMETAL_DIR" >&2; exit 1; }

REAL="$D3DMETAL_DIR/d3d11.dll"
ORIG="$D3DMETAL_DIR/d3d11_orig.dll"

[[ -f "$REAL" ]] || { echo "No d3d11.dll at $D3DMETAL_DIR" >&2; exit 1; }

if [[ ! -f "$ORIG" ]]; then
  cp "$REAL" "$ORIG"
  echo "Backed up real DLL -> $ORIG"
else
  echo "$ORIG already exists, leaving it (assumed already installed)"
fi

cp "$SCRIPT_DIR/build/x86_64/d3d11.dll" "$REAL"
echo "Installed shim -> $REAL"
