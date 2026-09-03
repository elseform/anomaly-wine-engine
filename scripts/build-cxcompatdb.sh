#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/env-x86_64.sh"

WINE_SRC="${WINE_SRC:-$ROOT/build/cx26/sources/wine}"
WINE_INSTALL="${WINE_INSTALL:-$ROOT/install/wine-cx26-x86_64}"
SOURCE="$ROOT/runtime/cxcompatdb/cxcompatdb.c"
OUTPUT="${GAMMA_CXCOMPATDB_OUTPUT:-$WINE_INSTALL/lib/wine/x86_64-unix/cxcompatdb.so}"
TARGET="${MACOSX_DEPLOYMENT_TARGET:-10.15}"
CONFIG_DIR="${GAMMA_CXCOMPATDB_CONFIG_DIR:-$WINE_SRC/build64/include}"

# OEM source snapshots are distributed without a configured build64 tree. The
# standalone plugin only needs Wine's public headers and the config include
# guard, so the OEM repack flow supplies a config.h copied from config.h.in.
[[ -f "$CONFIG_DIR/config.h" ]] || {
  echo "Missing cxcompatdb config header: $CONFIG_DIR/config.h" >&2
  echo "Set GAMMA_CXCOMPATDB_CONFIG_DIR to a configured Wine include directory." >&2
  exit 1
}

[[ -f "$WINE_SRC/include/winternl.h" ]] || {
  echo "Missing CrossOver Wine headers: $WINE_SRC/include" >&2
  exit 1
}

mkdir -p "$(dirname "$OUTPUT")"
clang_args=(
  -arch x86_64
  -dynamiclib -O2 -Wall -Wextra -Werror
  -mmacosx-version-min="$TARGET"
  -DWINE_UNIX_LIB
)
if [[ -n "${GAMMA_CXCOMPATDB_EXTRA_CFLAGS:-}" ]]; then
  extra_cflags=()
  read -r -a extra_cflags <<<"$GAMMA_CXCOMPATDB_EXTRA_CFLAGS"
  clang_args+=("${extra_cflags[@]}")
fi
clang_args+=(
  -I"$CONFIG_DIR" -I"$WINE_SRC/include" \
  -Wl,-undefined,dynamic_lookup \
  -Wl,-install_name,@loader_path/cxcompatdb.so \
)
arch -x86_64 /usr/bin/clang "${clang_args[@]}" -o "$OUTPUT" "$SOURCE"

echo "Built cxcompatdb: $OUTPUT"
otool -l "$OUTPUT" | awk '/minos/{print "  " $0; exit}'
