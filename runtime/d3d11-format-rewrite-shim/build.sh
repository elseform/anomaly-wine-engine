#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MINGW_BIN="$(ls -d "$REPO_ROOT"/build/llvm-mingw-*/bin | head -n 1)"

OUT_DIR="$SCRIPT_DIR/build/x86_64"
mkdir -p "$OUT_DIR"

echo "==> Building x86_64 d3d11 format-rewrite shim"
"$MINGW_BIN/x86_64-w64-mingw32-clang" \
  -shared \
  -O2 \
  -o "$OUT_DIR/d3d11.dll" \
  "$SCRIPT_DIR/shim.c" \
  "$SCRIPT_DIR/d3d11.def" \
  -Wl,--enable-stdcall-fixup

echo "==> Built $OUT_DIR/d3d11.dll"

# cxcompatdb's pe_is_builtin_for_machine() requires the literal marker
# "Wine builtin DLL" at DOS-header byte offset 64 before it will accept a
# candidate in lib/d3dmetal (or lib/dxmt) as a legitimate backend payload —
# every genuine Wine/GPTK-supplied DLL there carries it; a plain llvm-mingw
# build does not, and gets silently rejected ("invalid PE machine/signature
# or symlink") with a fallback to the next backend instead of a clear error.
python3 -c "
with open('$OUT_DIR/d3d11.dll', 'r+b') as f:
    f.seek(64)
    f.write(b'Wine builtin DLL')
"
echo "==> Patched Wine builtin DLL marker at offset 64"

"$MINGW_BIN/x86_64-w64-mingw32-objdump" -p "$OUT_DIR/d3d11.dll" | grep -A 10 "Export Table"
