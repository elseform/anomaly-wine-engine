#!/usr/bin/env bash
# Runs winetricks against a wrapper's prefix, using this engine's own Wine
# build (not system Wine) via Rosetta, matching how a wrapper app launches
# wine (its Contents/MacOS/launcher).
#
# Usage: GAMMA_APP=<wrapper name> scripts/run-winetricks.sh [winetricks args]
#   GAMMA_APP   wrapper app name without ".app" (e.g. the app in
#               ~/Applications/<name>.app). Selects the prefix at
#               ~/Library/Application Support/<name>/prefix and, when this
#               repository has no install/ tree, the wrapper's engine.
#   WINEPREFIX  overrides the prefix; GAMMA_APP is then needed only for the
#               engine fallback.
set -euo pipefail

GAMMA_APP="${GAMMA_APP:-}"
APP_DIR="$HOME/Applications/$GAMMA_APP.app"

ENGINE_DIR="$(cd "$(dirname "$0")/.." && pwd)/install/wine-cx26-x86_64"
if [[ ! -x "$ENGINE_DIR/bin/wine" && -n "$GAMMA_APP" ]]; then
  ENGINE_DIR="$APP_DIR/Contents/Resources/engine"
fi
if [[ ! -x "$ENGINE_DIR/bin/wine" ]]; then
  echo "error: could not find engine wine binary (checked repo install/${GAMMA_APP:+ and $APP_DIR}); set GAMMA_APP to a wrapper name" >&2
  exit 1
fi

if [[ -z "${WINEPREFIX:-}" ]]; then
  if [[ -z "$GAMMA_APP" ]]; then
    echo "error: set GAMMA_APP to a wrapper name, or WINEPREFIX to a prefix" >&2
    exit 1
  fi
  WINEPREFIX="$HOME/Library/Application Support/$GAMMA_APP/prefix"
fi
if [[ ! -d "$WINEPREFIX" ]]; then
  echo "error: prefix not found: $WINEPREFIX" >&2
  exit 1
fi
export WINEPREFIX

if ! command -v winetricks >/dev/null 2>&1; then
  echo "error: winetricks not found on PATH (expected e.g. /usr/local/bin/winetricks)" >&2
  exit 1
fi

WRAP_DIR="$(mktemp -d)"
trap 'rm -rf "$WRAP_DIR"' EXIT

cat > "$WRAP_DIR/wine" <<EOF
#!/usr/bin/env bash
exec arch -x86_64 "$ENGINE_DIR/bin/wine" "\$@"
EOF
cat > "$WRAP_DIR/wine64" <<EOF
#!/usr/bin/env bash
exec arch -x86_64 "$ENGINE_DIR/bin/wine64" "\$@"
EOF
cat > "$WRAP_DIR/wineserver" <<EOF
#!/usr/bin/env bash
exec arch -x86_64 "$ENGINE_DIR/bin/wineserver" "\$@"
EOF
chmod +x "$WRAP_DIR/wine" "$WRAP_DIR/wine64" "$WRAP_DIR/wineserver"

export WINE="$WRAP_DIR/wine"
export WINE64="$WRAP_DIR/wine64"
export WINESERVER="$WRAP_DIR/wineserver"
export WINELOADER="$WRAP_DIR/wine"
export PATH="$WRAP_DIR:$PATH"

echo "engine:    $ENGINE_DIR"
echo "prefix:    $WINEPREFIX"
echo "winetricks: $(command -v winetricks) $*"
echo

exec winetricks "$@"
