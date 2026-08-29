#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MINGW_BIN="$(ls -d "$REPO_ROOT"/build/llvm-mingw-*/bin | head -n 1)"

OUT_DIR="$SCRIPT_DIR/build/x86_64"
mkdir -p "$OUT_DIR"

echo "==> Building x86_64 d3dx11_43 shim"
"$MINGW_BIN/x86_64-w64-mingw32-clang" \
  -shared \
  -O2 \
  -o "$OUT_DIR/d3dx11_43.dll" \
  "$SCRIPT_DIR/shim.c" \
  "$SCRIPT_DIR/d3dx11_43.def" \
  -Wl,--enable-stdcall-fixup

echo "==> Built $OUT_DIR/d3dx11_43.dll"
"$MINGW_BIN/x86_64-w64-mingw32-objdump" -p "$OUT_DIR/d3dx11_43.dll" | grep -A 60 "Export Table" | head -70
