#!/usr/bin/env bash
# Runs winetricks against the GAMMA prefix, using this engine's own Wine
# build (not system Wine) via Rosetta, matching how GAMMA.app itself launches
# wine (see Contents/MacOS/launcher and scripts/interactive-setup.sh).
set -euo pipefail

ENGINE_DIR="$(cd "$(dirname "$0")/.." && pwd)/install/wine-cx26-x86_64"
if [[ ! -x "$ENGINE_DIR/bin/wine" ]]; then
  ENGINE_DIR="/Users/elseform/Applications/GAMMA.app/Contents/Resources/engine"
fi
if [[ ! -x "$ENGINE_DIR/bin/wine" ]]; then
  echo "error: could not find engine wine binary (checked repo install/ and GAMMA.app)" >&2
  exit 1
fi

export WINEPREFIX="/Users/elseform/Library/Application Support/GAMMA/prefix"

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
