#!/usr/bin/env bash
# Interactive setup: builds a macOS .app around the packaged Wine engine.
#
# Bundle layout:
#   <App>.app/Contents/MacOS/launcher        thin launcher, paths baked in
#   <App>.app/Contents/MacOS/winetricks      prefix-aware winetricks launcher
#   <App>.app/Contents/Resources/engine/     engine tree (read-only, signed)
#
# Mutable state lives outside the bundle so the app stays signable and
# replaceable:
#   ~/Library/Application Support/<App>/prefix    Wine prefix
#   ~/Library/Application Support/<App>/app.env   user-editable settings
#
# Standalone — does not call other scripts in this repo.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

prompt_path() {
  local message="$1" default="$2" reply
  read -r -p "$message [$default]: " reply || true
  echo "${reply:-$default}"
}

is_d3dmetal_family() {
  case "$1" in d3dmetal) return 0 ;; *) return 1 ;; esac
}

echo "=========================================================="
echo "GAMMA Wine Engine — Interactive Setup"
echo "=========================================================="

# 1. Collect paths
DEFAULT_ARTIFACT="$(ls -t "$REPO_ROOT"/dist/artifacts/*.tar.zst 2>/dev/null | head -n 1 || true)"
while true; do
  ARTIFACT_PATH="$(prompt_path "Path to engine tar.xz" "${DEFAULT_ARTIFACT:-$REPO_ROOT/dist/artifacts/engine.tar.xz}")"
  ARTIFACT_PATH="${ARTIFACT_PATH/#\~/$HOME}"
  [[ -f "$ARTIFACT_PATH" ]] && break
  echo "  Not found: $ARTIFACT_PATH"
done

APP_NAME="$(prompt_path "Name for the .app bundle (without .app)" "GAMMA")"
APP_NAME="${APP_NAME%.app}"

APP_DIR_PARENT="$(prompt_path "Directory to place the .app in" "$HOME/Applications")"
APP_DIR_PARENT="${APP_DIR_PARENT/#\~/$HOME}"
APP_PATH="$APP_DIR_PARENT/$APP_NAME.app"

GAMMA_ROOT="$(prompt_path "Path to game root (G: drive)" "$HOME/gamma")"
GAMMA_ROOT="${GAMMA_ROOT/#\~/$HOME}"

while true; do
  EXE_REL_PATH="$(prompt_path "Path to .exe, relative to game root" "sss23/bin/AnomalyDX11AVX.exe")"
  EXE_REL_PATH="${EXE_REL_PATH#/}"
  [[ -f "$GAMMA_ROOT/$EXE_REL_PATH" ]] && break
  echo "  Not found: $GAMMA_ROOT/$EXE_REL_PATH"
  read -r -p "  Use anyway? [y/N]: " force || true
  [[ "${force:-N}" =~ ^[Yy] ]] && break
done
EXE_WIN_PATH="G:\\${EXE_REL_PATH//\//\\}"
EXE_RUN_DIR="$GAMMA_ROOT/$(dirname "$EXE_REL_PATH")"

echo ""
echo "Graphics backend:"
echo "  1) d3dmetal  Apple D3DMetal — D3D11/12 via Metal (default, 64-bit only)"
echo "  2) dxmt      DXMT — D3D11/10 via Metal (works for 32-bit too)"
echo "  3) dxvk      DXVK — D3D11/10/9 via Vulkan/MoltenVK (needs a Vulkan engine build)"
BACKEND_CHOICE="$(prompt_path "Select backend" "1")"
case "$BACKEND_CHOICE" in
  1|d3dmetal) GRAPHICS_BACKEND=d3dmetal ;;
  2|dxmt)     GRAPHICS_BACKEND=dxmt ;;
  3|dxvk)     GRAPHICS_BACKEND=dxvk ;;
  *)
    echo "  Unrecognized choice '$BACKEND_CHOICE', using d3dmetal"
    GRAPHICS_BACKEND=d3dmetal
    ;;
esac

if is_d3dmetal_family "$GRAPHICS_BACKEND"; then
  echo ""
  echo "D3DMetal (GPTK) version, used only when the launcher swaps files in at"
  echo "startup (see D3DMETAL_USER_BACKEND in app.env — changeable any time,"
  echo "no rebuild needed):"
  echo "  1) gptk40b2  better perf/visual quality (recommended)"
  echo "  2) gptk40b1  no d3d10 payload, slightly lower quality"
  GPTK_CHOICE="$(prompt_path "Select GPTK version" "1")"
  case "$GPTK_CHOICE" in
    1|gptk40b2|beta2|b2) GPTK_USER_BACKEND=gptk40b2 ;;
    2|gptk40b1|beta1|b1) GPTK_USER_BACKEND=gptk40b1 ;;
    *)
      echo "  Unrecognized choice '$GPTK_CHOICE', using gptk40b2"
      GPTK_USER_BACKEND=gptk40b2
      ;;
  esac
else
  GPTK_USER_BACKEND=gptk40b2
fi

echo ""
echo "cxcompatdb policy:"
echo "  1) real         Full production policy (default)"
echo "  2) debug_dummy  Policy-isolation build"
echo "     Keeps explicit GAMMA backend switching and winemenubuilder suppression"
echo "     Removes automatic selection, legacy aliases, DirectX helper overrides, and rule actions"
CXCOMPATDB_CHOICE="$(prompt_path "Select cxcompatdb" "1")"
case "$CXCOMPATDB_CHOICE" in
  1|real|full) CXCOMPATDB_VARIANT=real ;;
  2|debug_dummy|dummy_debug|dummy|debug) CXCOMPATDB_VARIANT=debug_dummy ;;
  *)
    echo "  Unrecognized choice '$CXCOMPATDB_CHOICE', using real"
    CXCOMPATDB_VARIANT=real
    ;;
esac

echo ""
read -r -p "Enable Retina/HiDPI mode (CrossOver's Retina toggle equivalent)? [y/N]: " retina_choice || true
if [[ "${retina_choice:-N}" =~ ^[Yy] ]]; then
  RETINA_MODE=Y
else
  RETINA_MODE=N
fi

APP_SUPPORT="$HOME/Library/Application Support/$APP_NAME"
WINEPREFIX="$APP_SUPPORT/prefix"
ENGINE_DIR="$APP_PATH/Contents/Resources/engine"
CONFIG_FILE="$APP_SUPPORT/app.env"

echo ""
echo "  Engine tar.xz:  $ARTIFACT_PATH"
echo "  App bundle:     $APP_PATH"
echo "  Engine (in app):$ENGINE_DIR"
echo "  Prefix:         $WINEPREFIX"
echo "  Settings:       $CONFIG_FILE"
echo "  Game root:      $GAMMA_ROOT"
echo "  Backend:        $GRAPHICS_BACKEND"
echo "  cxcompatdb:      $CXCOMPATDB_VARIANT"
echo ""
read -r -p "Proceed? [Y/n]: " confirm || true
if [[ "${confirm:-Y}" =~ ^[Nn] ]]; then
  echo "Aborted."
  exit 1
fi

# 2. Create app skeleton, extract engine
echo ""
echo "==> Step 1: Extracting Wine engine into app bundle..."
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" "$ENGINE_DIR" "$APP_SUPPORT"
cp "$SCRIPT_DIR/Anomaly.icns" "$APP_PATH/Contents/Resources/Anomaly.icns"
tar -xf "$ARTIFACT_PATH" -C "$ENGINE_DIR" --strip-components=1

if [[ ! -x "$ENGINE_DIR/bin/wine" ]]; then
  echo "Error: wine binary missing after extraction at $ENGINE_DIR/bin/wine" >&2
  exit 1
fi
arch -x86_64 "$ENGINE_DIR/bin/wine" --version

CXCOMPATDB_DIR="$ENGINE_DIR/lib/wine/x86_64-unix"
[[ -f "$CXCOMPATDB_DIR/cxcompatdb.so" ]] || {
  echo "Error: engine artifact has no real cxcompatdb.so" >&2
  exit 1
}
if [[ "$CXCOMPATDB_VARIANT" == "debug_dummy" ]]; then
  [[ -f "$CXCOMPATDB_DIR/cxcompatdb-debug_dummy.so" ]] || {
    echo "Error: engine artifact has no debug_dummy cxcompatdb; rebuild it with current scripts/build-wine.sh" >&2
    exit 1
  }
  cp "$CXCOMPATDB_DIR/cxcompatdb-debug_dummy.so" "$CXCOMPATDB_DIR/cxcompatdb.so"
  echo "  Activated debug_dummy cxcompatdb"
fi

ENGINE_VERSION="$(head -n 1 "$ENGINE_DIR/version" 2>/dev/null || echo "1.0.0")"

# Warn early when the selected backend is not actually present in the engine.
if is_d3dmetal_family "$GRAPHICS_BACKEND"; then
  [[ -d "$ENGINE_DIR/lib/$GRAPHICS_BACKEND" ]] || echo "  Warning: engine has no lib/$GRAPHICS_BACKEND" >&2
else
  case "$GRAPHICS_BACKEND" in
    dxmt)     [[ -d "$ENGINE_DIR/lib/dxmt" ]] || echo "  Warning: engine has no lib/dxmt" >&2 ;;
    dxvk)
      [[ -d "$ENGINE_DIR/lib/dxvk" ]] || echo "  Warning: engine has no lib/dxvk" >&2
      if [[ ! -f "$ENGINE_DIR/lib/wine/x86_64-unix/libMoltenVK.dylib" &&
            ! -f "$ENGINE_DIR/lib64/libMoltenVK.dylib" ]]; then
        echo "  Warning: engine has no libMoltenVK.dylib — DXVK will fall back to wined3d" >&2
      fi
      ;;
  esac
fi

# 3. Bootstrap prefix (outside the bundle)
echo ""
echo "==> Step 2: Bootstrapping Wine prefix..."
arch -x86_64 "$ENGINE_DIR/bin/wineserver" -k 2>/dev/null || true
mkdir -p "$WINEPREFIX"

WINEPREFIX="$WINEPREFIX" arch -x86_64 "$ENGINE_DIR/bin/wine" wineboot -u
WINEPREFIX="$WINEPREFIX" arch -x86_64 "$ENGINE_DIR/bin/wineserver" -w

echo "==> Step 2.2: Drive mappings & user profile..."
mkdir -p "$WINEPREFIX/dosdevices"
ln -sfn "/" "$WINEPREFIX/dosdevices/z:"
ln -sfn "../drive_c" "$WINEPREFIX/dosdevices/c:"
ln -sfn "$GAMMA_ROOT" "$WINEPREFIX/dosdevices/g:"

mkdir -p "$WINEPREFIX/drive_c/users/Sikarugir"
ln -sfn "Sikarugir" "$WINEPREFIX/drive_c/users/crossover"
ln -sfn "Sikarugir" "$WINEPREFIX/drive_c/users/$USER"

echo "==> Step 2.3: Registry overrides..."
wine_reg() {
  WINEPREFIX="$WINEPREFIX" arch -x86_64 "$ENGINE_DIR/bin/wine" reg add "$@" >/dev/null
}
wine_reg "HKEY_CURRENT_USER\Software\Wine\Drivers" /v Graphics /t REG_SZ /d mac /f
wine_reg "HKEY_CURRENT_USER\Software\Wine\Mac Driver" /v AllowSetGamma /t REG_DWORD /d 0 /f
wine_reg "HKEY_CURRENT_USER\Software\Wine\Mac Driver" /v RetinaMode /t REG_SZ /d "$RETINA_MODE" /f

# d3d11/dxgi/d3d12 deliberately get no registry DllOverrides here: cxcompatdb.so
# activates the selected backend by prepending its directory to the DLL search
# path at process start, not via registry overrides. Forcing these to "builtin"
# in the registry would fight that mechanism and pin wined3d/Wine's own D3D11
# regardless of GAMMA_GRAPHICS_BACKEND.
for dll in "*d3dcompiler_43" "*d3dcompiler_47" "*d3dx9_43" "*d3dx10_43" "*d3dx11_43" \
           "*concrt140" "*msvcp140" "*msvcp140_1" "*msvcp140_2" \
           "*msvcp140_atomic_wait" "*msvcp140_codecvt_ids" \
           "*vcamp140" "*vccorlib140" "*vcomp140" "*vcruntime140" "*vcruntime140_1"; do
  wine_reg "HKEY_CURRENT_USER\Software\Wine\DllOverrides" /v "$dll" /t REG_SZ /d "native,builtin" /f
done
wine_reg "HKEY_CURRENT_USER\Software\Wine\DllOverrides" /v "winemenubuilder.exe" /t REG_SZ /d "" /f

# d3d10 gets a per-app (not global) override, scoped to the game's own exe:
# GPTK's own d3d10.dll (when present) trips a save-game hang (see
# docs/d3dmetal-savegame-crash.md); this pins d3d10 at Wine's own genuine,
# independent implementation instead of leaving resolution to chance. Applies
# to all d3dmetal-family backends — gptk40b1 also ships no d3d10.dll of its
# own, so it has the same unproven-default-resolution gap. Harmless either
# way: this game never calls D3D10CreateDevice, only D3DX11's internal
# D3D10CreateBlob dependency needs it to resolve at all.
if is_d3dmetal_family "$GRAPHICS_BACKEND"; then
  EXE_BASENAME="$(basename "$EXE_REL_PATH")"
  wine_reg "HKEY_CURRENT_USER\Software\Wine\AppDefaults\\$EXE_BASENAME\DllOverrides" \
    /v d3d10 /t REG_SZ /d builtin /f
  echo "  Added d3d10=builtin override for $EXE_BASENAME"
fi

echo "==> Step 2.4: Installing vendored DirectX/VC++ redistributables..."
REDIST_DIR="$ENGINE_DIR/redist"
[[ -d "$REDIST_DIR" ]] || REDIST_DIR="$REPO_ROOT/runtime/redist"
SYS64="$WINEPREFIX/drive_c/windows/system32"
SYS32="$WINEPREFIX/drive_c/windows/syswow64"
if [[ -d "$REDIST_DIR/x86_64-windows" ]]; then
  cp -f "$REDIST_DIR/x86_64-windows/"*.dll "$SYS64/"
fi
if [[ -d "$REDIST_DIR/i386-windows" && -d "$SYS32" ]]; then
  cp -f "$REDIST_DIR/i386-windows/"*.dll "$SYS32/"
fi

WINEPREFIX="$WINEPREFIX" arch -x86_64 "$ENGINE_DIR/bin/wine" "$ENGINE_DIR/lib/wine/x86_64-windows/winecfg.exe" -v win10
WINEPREFIX="$WINEPREFIX" arch -x86_64 "$ENGINE_DIR/bin/wineserver" -w

wine_reg "HKEY_CURRENT_USER\Software\Wine\Drivers" /v Audio /t REG_SZ /d coreaudio /f

WINEPREFIX="$WINEPREFIX" arch -x86_64 "$ENGINE_DIR/bin/wineserver" -w

# 4. Bundle metadata, settings file, launcher
echo ""
echo "==> Step 3: Writing .app bundle metadata & launcher..."

cat > "$APP_PATH/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>English</string>
	<key>CFBundleDisplayName</key>
	<string>$APP_NAME</string>
	<key>CFBundleExecutable</key>
	<string>launcher</string>
	<key>CFBundleIconFile</key>
	<string>Anomaly.icns</string>
	<key>CFBundleIdentifier</key>
	<string>com.gamma.wine-engine.$(echo "$APP_NAME" | tr '[:upper:] ' '[:lower:]-')</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>1.0</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$ENGINE_VERSION</string>
	<key>CFBundleVersion</key>
	<string>$ENGINE_VERSION</string>
	<key>LSMinimumSystemVersion</key>
	<string>10.15</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSSupportsAutomaticGraphicsSwitching</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
EOF

# Settings live outside the bundle: editing them must not break the signature.
if [[ -f "$CONFIG_FILE" ]]; then
  echo "  Keeping existing settings: $CONFIG_FILE"
else
  TEMPLATE_FILE="$REPO_ROOT/config/app.env.template"
  content="$(cat "$TEMPLATE_FILE")"
  content="${content//\{\{APP_NAME\}\}/$APP_NAME}"
  content="${content//\{\{GRAPHICS_BACKEND\}\}/$GRAPHICS_BACKEND}"
  content="${content//\{\{EXE_WIN_PATH\}\}/$EXE_WIN_PATH}"
  content="${content//\{\{EXE_RUN_DIR\}\}/$EXE_RUN_DIR}"
  content="${content//\{\{RETINA_MODE\}\}/$RETINA_MODE}"
  content="${content//\{\{GPTK_USER_BACKEND\}\}/$GPTK_USER_BACKEND}"
  printf '%s\n' "$content" > "$CONFIG_FILE"
  echo "  Wrote settings: $CONFIG_FILE"
fi

cat > "$APP_PATH/Contents/MacOS/launcher" << EOF
#!/usr/bin/env bash
set -euo pipefail

APP_DIR="\$(cd "\$(dirname "\$0")/../.." && pwd)"
ENGINE_DIR="\$APP_DIR/Contents/Resources/engine"
APP_SUPPORT="$APP_SUPPORT"
CONFIG_FILE="\$APP_SUPPORT/app.env"

export WINEPREFIX="\$APP_SUPPORT/prefix"

# User settings (outside the bundle) win over the defaults below.
if [[ -f "\$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "\$CONFIG_FILE"
fi

export GAMMA_GRAPHICS_BACKEND="\${GAMMA_GRAPHICS_BACKEND:-$GRAPHICS_BACKEND}"
export WINEMSYNC="\${WINEMSYNC:-1}"
export WINEESYNC="\${WINEESYNC:-1}"
export ROSETTA_ADVERTISE_AVX="\${ROSETTA_ADVERTISE_AVX:-1}"
export MTL_HUD_ENABLED="\${MTL_HUD_ENABLED:-1}"
export WINEDEBUG="\${WINEDEBUG:--all}"
export WINEBOOT_HIDE_DIALOG=1
export LC_ALL="en_US.UTF-8"
export LANG="en_US.UTF-8"

# Swap which GPTK beta occupies lib/d3dmetal + lib/external before wine
# ever starts — cxcompatdb.so stays completely unaware of beta names, it
# only ever sees the plain "d3dmetal" backend it's always known. See
# docs/d3dmetal-savegame-crash.md.
if [[ "\$GAMMA_GRAPHICS_BACKEND" == "d3dmetal" ]]; then
  "\$APP_DIR/Contents/Resources/select-gptk-beta.sh" "\$ENGINE_DIR" || true
fi

# D3DMetal needs its framework and shared library located explicitly. Only
# export them when D3DMetal can actually be selected: cxcompatdb.so sets
# CX_APPLEGPTK_LIBD3DSHARED_PATH itself once a backend is active, and forcing
# these for a DXMT or DXVK run points the process at the wrong renderer.
case "\$GAMMA_GRAPHICS_BACKEND" in
  d3dmetal)
    if [[ -f "\$ENGINE_DIR/lib/external/libd3dshared.dylib" ]]; then
      export CX_APPLEGPTK_LIBD3DSHARED_PATH="\$ENGINE_DIR/lib/external/libd3dshared.dylib"
    fi
    if [[ -d "\$ENGINE_DIR/lib/external/D3DMetal.framework" ]]; then
      export CX_D3DMETALPATH="\$ENGINE_DIR/lib/external/D3DMetal.framework"
    fi
    ;;
esac

GAMMA_RETINA_MODE="\${GAMMA_RETINA_MODE:-N}"
WINEPREFIX="\$WINEPREFIX" arch -x86_64 "\$ENGINE_DIR/bin/wine" reg add \\
  "HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver" /v RetinaMode /t REG_SZ /d "\$GAMMA_RETINA_MODE" /f \\
  >/dev/null 2>&1 || true
if [[ "\$GAMMA_RETINA_MODE" == "Y" && -n "\${GAMMA_RETINA_LOGPIXELS:-}" ]]; then
  WINEPREFIX="\$WINEPREFIX" arch -x86_64 "\$ENGINE_DIR/bin/wine" reg add \\
    "HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver" /v LogPixels /t REG_DWORD /d "\$GAMMA_RETINA_LOGPIXELS" /f \\
    >/dev/null 2>&1 || true
fi

EXE_PATH="\${EXE_PATH:-$EXE_WIN_PATH}"
EXE_RUN_DIR="\${EXE_RUN_DIR:-$EXE_RUN_DIR}"

cd "\$EXE_RUN_DIR"

# Bring window to frontmost focus for DirectInput capture
(
  sleep 2
  osascript -e 'tell application "System Events" to set frontmost of (first process whose name contains "wine" or name contains "Anomaly") to true' 2>/dev/null || true
) &

# bash 3.2 on macOS chokes on "\${@}" under set -u when empty
if [[ \$# -eq 0 && -n "\${DEFAULT_GAME_ARGS:-}" ]]; then
  # shellcheck disable=SC2086
  set -- \$DEFAULT_GAME_ARGS
fi

exec taskpolicy -l 0 -t 0 arch -x86_64 "\$ENGINE_DIR/bin/wine" "\$EXE_PATH" "\$@"
EOF

cat > "$APP_PATH/Contents/MacOS/winetricks" << EOF
#!/usr/bin/env bash
# Runs winetricks against this app's prefix with its bundled Wine engine.
set -euo pipefail

APP_DIR="\$(cd "\$(dirname "\$0")/../.." && pwd)"
ENGINE_DIR="\$APP_DIR/Contents/Resources/engine"
export WINEPREFIX="$WINEPREFIX"

if [[ ! -x "\$ENGINE_DIR/bin/wine" || ! -x "\$ENGINE_DIR/bin/wineserver" ]]; then
  echo "error: bundled Wine engine is incomplete: \$ENGINE_DIR" >&2
  exit 1
fi

WINETRICKS_BIN="\${WINETRICKS_BIN:-}"
if [[ -z "\$WINETRICKS_BIN" ]]; then
  for candidate in /opt/homebrew/bin/winetricks /usr/local/bin/winetricks; do
    if [[ -x "\$candidate" ]]; then
      WINETRICKS_BIN="\$candidate"
      break
    fi
  done
fi
if [[ -z "\$WINETRICKS_BIN" ]]; then
  candidate="\$(command -v winetricks 2>/dev/null || true)"
  if [[ -n "\$candidate" && "\$candidate" != "\$0" ]]; then
    WINETRICKS_BIN="\$candidate"
  fi
fi
if [[ -z "\$WINETRICKS_BIN" || ! -x "\$WINETRICKS_BIN" ]]; then
  echo "error: winetricks not found; install it or set WINETRICKS_BIN to its executable path" >&2
  exit 1
fi

WRAP_DIR="\$(mktemp -d "\${TMPDIR:-/tmp}/gamma-winetricks.XXXXXX")"
cleanup() {
  rm -rf "\$WRAP_DIR"
}
trap cleanup EXIT

cat > "\$WRAP_DIR/wine-wrapper" << 'WRAPPER_EOF'
#!/usr/bin/env bash
set -euo pipefail
binary="\$(basename "\$0")"
if [[ "\$binary" == "wine64" && ! -x "\$GAMMA_WINETRICKS_ENGINE/bin/wine64" ]]; then
  binary=wine
fi
exec arch -x86_64 "\$GAMMA_WINETRICKS_ENGINE/bin/\$binary" "\$@"
WRAPPER_EOF
chmod +x "\$WRAP_DIR/wine-wrapper"
ln -s wine-wrapper "\$WRAP_DIR/wine"
ln -s wine-wrapper "\$WRAP_DIR/wine64"
ln -s wine-wrapper "\$WRAP_DIR/wineserver"

export GAMMA_WINETRICKS_ENGINE="\$ENGINE_DIR"
export WINE="\$WRAP_DIR/wine"
export WINE64="\$WRAP_DIR/wine64"
export WINESERVER="\$WRAP_DIR/wineserver"
export WINELOADER="\$WRAP_DIR/wine"
export PATH="\$WRAP_DIR:\$PATH"

echo "engine:     \$ENGINE_DIR"
echo "prefix:     \$WINEPREFIX"
echo "winetricks: \$WINETRICKS_BIN \$*"
echo

status=0
"\$WINETRICKS_BIN" "\$@" || status=\$?
exit "\$status"
EOF

cat > "$APP_PATH/Contents/Resources/select-gptk-beta.sh" << 'EOF'
#!/usr/bin/env bash
# Swaps which GPTK beta occupies lib/d3dmetal + lib/external, driven by
# D3DMETAL_USER_BACKEND (gptk40b1 | gptk40b2, from app.env). Runs before
# every launch when GAMMA_GRAPHICS_BACKEND=d3dmetal. cxcompatdb.so never
# learns about beta names — see docs/d3dmetal-savegame-crash.md.
set -euo pipefail
ENGINE_DIR="$1"
BETA="${D3DMETAL_USER_BACKEND:-gptk40b2}"
SRC="$ENGINE_DIR/lib/$BETA"
[[ -d "$SRC/external" ]] || exit 0
rm -rf "$ENGINE_DIR/lib/external" "$ENGINE_DIR/lib/d3dmetal"
mkdir -p "$ENGINE_DIR/lib/external" \
         "$ENGINE_DIR/lib/d3dmetal/x86_64-windows" \
         "$ENGINE_DIR/lib/d3dmetal/x86_64-unix"
cp -R "$SRC/external/." "$ENGINE_DIR/lib/external/"
cp -R "$SRC/x86_64-windows/." "$ENGINE_DIR/lib/d3dmetal/x86_64-windows/"
cp -R "$SRC/x86_64-unix/." "$ENGINE_DIR/lib/d3dmetal/x86_64-unix/"
ln -sfn ../external "$ENGINE_DIR/lib/d3dmetal/external"
EOF
chmod +x "$APP_PATH/Contents/Resources/select-gptk-beta.sh"

chmod +x "$APP_PATH/Contents/MacOS/launcher" "$APP_PATH/Contents/MacOS/winetricks"

# 5. Ad-hoc sign the bundle. The engine payload is already signed by
#    pack-engine-artifact.sh, so only the wrapper needs a signature.
echo "==> Step 4: Signing bundle..."
codesign --force --sign - --timestamp=none "$APP_PATH/Contents/MacOS/launcher" 2>/dev/null || true
codesign --force --sign - --timestamp=none "$APP_PATH/Contents/MacOS/winetricks" 2>/dev/null || true
if codesign --force --sign - --timestamp=none "$APP_PATH" 2>/dev/null; then
  echo "  Ad-hoc signed $APP_PATH"
else
  echo "  Warning: could not sign the bundle (it will still run locally)" >&2
fi

echo "==> Step 5: Registering with Launch Services..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_PATH" 2>/dev/null || true

echo ""
echo "=========================================================="
echo "Setup complete."
echo "  App:      $APP_PATH"
echo "  Engine:   $ENGINE_DIR  (inside app, read-only)"
echo "  Prefix:   $WINEPREFIX"
echo "  Settings: $CONFIG_FILE"
echo "  Backend:  $GRAPHICS_BACKEND  (change it in app.env, no rebuild needed)"
echo "  cxcompatdb: $CXCOMPATDB_VARIANT"
if is_d3dmetal_family "$GRAPHICS_BACKEND"; then
  echo "  GPTK:     $GPTK_USER_BACKEND (change D3DMETAL_USER_BACKEND in app.env, no rebuild needed)"
  echo "            d3d10.dll/.so excluded from payload, d3d10=builtin override"
  echo "            added for $(basename "$EXE_REL_PATH")"
fi
echo ""
echo "Launch via:  open \"$APP_PATH\""
echo "Or CLI:      \"$APP_PATH/Contents/MacOS/launcher\" -dbg -nointro"
echo "Winetricks:  \"$APP_PATH/Contents/MacOS/winetricks\" [verb ...]"
echo "=========================================================="
