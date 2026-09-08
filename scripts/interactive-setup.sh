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

resolve_winetricks() {
  local candidate cache_dir
  if [[ -n "${WINETRICKS_BIN:-}" && -x "$WINETRICKS_BIN" ]]; then
    printf '%s\n' "$WINETRICKS_BIN"
    return 0
  fi
  for candidate in /opt/homebrew/bin/winetricks /usr/local/bin/winetricks; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  candidate="$(command -v winetricks 2>/dev/null || true)"
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  cache_dir="$APP_SUPPORT/cache/winetricks"
  candidate="$cache_dir/winetricks"
  if [[ ! -x "$candidate" ]]; then
    mkdir -p "$cache_dir"
    echo "  Downloading current winetricks script..." >&2
    if ! curl -fL --retry 2 \
      https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks \
      -o "$candidate"; then
      rm -f "$candidate"
      return 1
    fi
    chmod +x "$candidate"
  fi
  printf '%s\n' "$candidate"
}

run_winetricks() {
  local winetricks_bin="$1" wrap_dir status=0
  shift
  wrap_dir="$(mktemp -d "${TMPDIR:-/tmp}/gamma-winetricks.XXXXXX")"
  cat > "$wrap_dir/wine-wrapper" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
binary="$(basename "$0")"
if [[ "$binary" == "wine64" && ! -x "$GAMMA_WINETRICKS_ENGINE/bin/wine64" ]]; then
  binary=wine
fi
exec arch -x86_64 "$GAMMA_WINETRICKS_ENGINE/bin/$binary" "$@"
EOF
  chmod +x "$wrap_dir/wine-wrapper"
  ln -s wine-wrapper "$wrap_dir/wine"
  ln -s wine-wrapper "$wrap_dir/wine64"
  ln -s wine-wrapper "$wrap_dir/wineserver"
  GAMMA_WINETRICKS_ENGINE="$ENGINE_DIR" \
  WINEPREFIX="$WINEPREFIX" \
  WINE="$wrap_dir/wine" \
  WINE64="$wrap_dir/wine64" \
  WINESERVER="$wrap_dir/wineserver" \
  WINELOADER="$wrap_dir/wine" \
  W_CACHE="$APP_SUPPORT/cache/winetricks/downloads" \
  PATH="$wrap_dir:$PATH" \
    "$winetricks_bin" "$@" || status=$?
  rm -rf "$wrap_dir"
  return "$status"
}

echo "=========================================================="
echo "GAMMA Wine Engine — Interactive Setup"
echo "=========================================================="

# 1. Collect paths
DEFAULT_ARTIFACT="$(ls -t \
  "$REPO_ROOT"/dist/artifacts/*.tar.zst \
  "$REPO_ROOT"/dist/artifacts/*.tar.xz \
  2>/dev/null | head -n 1 || true)"
while true; do
  ARTIFACT_PATH="$(prompt_path "Path to engine archive (.tar.zst or .tar.xz)" "${DEFAULT_ARTIFACT:-$REPO_ROOT/dist/artifacts/engine.tar.zst}")"
  ARTIFACT_PATH="${ARTIFACT_PATH/#\~/$HOME}"
  [[ -f "$ARTIFACT_PATH" ]] && break
  echo "  Not found: $ARTIFACT_PATH"
done

APP_NAME="$(prompt_path "Name for the .app bundle (without .app)" "GAMMA")"
APP_NAME="${APP_NAME%.app}"

APP_DIR_PARENT="$(prompt_path "Directory to place the .app in" "$HOME/Applications")"
APP_DIR_PARENT="${APP_DIR_PARENT/#\~/$HOME}"
APP_PATH="$APP_DIR_PARENT/$APP_NAME.app"

if [[ -e "$APP_PATH" ]]; then
  echo "Error: $APP_PATH already exists. This script never overwrites an" >&2
  echo "existing wrapper (it would corrupt that app's Wine prefix). Choose a" >&2
  echo "different name, or remove the existing .app and its" >&2
  echo "~/Library/Application Support/$APP_NAME/ first." >&2
  exit 1
fi

GAMMA_ROOT="$(prompt_path "Path to game root (G: drive)" "$HOME/gamma")"
GAMMA_ROOT="${GAMMA_ROOT/#\~/$HOME}"

while true; do
  EXE_REL_PATH="$(prompt_path "Path to .exe, relative to game root" "sept/bin/AnomalyDX11AVX.exe")"
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
BACKEND_CHOICE="$(prompt_path "Select backend" "1")"
case "$BACKEND_CHOICE" in
  1|d3dmetal) GRAPHICS_BACKEND=d3dmetal ;;
  2|dxmt)     GRAPHICS_BACKEND=dxmt ;;
  *)
    echo "  Unrecognized choice '$BACKEND_CHOICE', using d3dmetal"
    GRAPHICS_BACKEND=d3dmetal
    ;;
esac

echo ""
echo "Runtime dependencies:"
echo "  1) verbs   Install required components with winetricks (recommended)"
echo "  2) redist  Copy bundled DLLs and register fallback overrides"
RUNTIME_CHOICE="$(prompt_path "Select dependency source" "1")"
case "$RUNTIME_CHOICE" in
  1|verbs|winetricks) RUNTIME_MODE=verbs ;;
  2|redist|dlls)      RUNTIME_MODE=redist ;;
  *)
    echo "  Unrecognized choice '$RUNTIME_CHOICE', using verbs"
    RUNTIME_MODE=verbs
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
echo "  Engine archive: $ARTIFACT_PATH"
echo "  App bundle:     $APP_PATH"
echo "  Engine (in app):$ENGINE_DIR"
echo "  Prefix:         $WINEPREFIX"
echo "  Settings:       $CONFIG_FILE"
echo "  Game root:      $GAMMA_ROOT"
echo "  Backend:        $GRAPHICS_BACKEND"
echo "  Dependencies:   $RUNTIME_MODE"
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
case "$ARTIFACT_PATH" in
  *.tar.zst)
    ZSTD_BIN="$(command -v zstd 2>/dev/null || true)"
    [[ -x "$ZSTD_BIN" ]] || ZSTD_BIN="/opt/homebrew/bin/zstd"
    [[ -x "$ZSTD_BIN" ]] || ZSTD_BIN="/usr/local/bin/zstd"
    [[ -x "$ZSTD_BIN" ]] || {
      echo "zstd is required to extract $ARTIFACT_PATH (brew install zstd)" >&2
      exit 1
    }
    "$ZSTD_BIN" -dc "$ARTIFACT_PATH" | tar -xf - -C "$ENGINE_DIR" --strip-components=1
    ;;
  *.tar.xz)
    tar -xJf "$ARTIFACT_PATH" -C "$ENGINE_DIR" --strip-components=1
    ;;
  *)
    echo "Unsupported engine archive: $ARTIFACT_PATH (expected .tar.zst or .tar.xz)" >&2
    exit 1
    ;;
esac

if [[ ! -x "$ENGINE_DIR/bin/wine" ]]; then
  echo "Error: wine binary missing after extraction at $ENGINE_DIR/bin/wine" >&2
  exit 1
fi
arch -x86_64 "$ENGINE_DIR/bin/wine" --version

CXCOMPATDB_DIR="$ENGINE_DIR/lib/wine/x86_64-unix"
[[ -f "$CXCOMPATDB_DIR/cxcompatdb.so" ]] || {
  echo "Error: engine artifact has no cxcompatdb.so" >&2
  exit 1
}

ENGINE_VERSION="$(head -n 1 "$ENGINE_DIR/version" 2>/dev/null || echo "1.0.0")"

# Warn early when the selected backend is not actually present in the engine.
if is_d3dmetal_family "$GRAPHICS_BACKEND"; then
  [[ -d "$ENGINE_DIR/lib64/apple_gptk/wine" ]] || {
    echo "Error: engine has no lib64/apple_gptk/wine" >&2
    exit 1
  }
else
  [[ -d "$ENGINE_DIR/lib/dxmt" ]] || {
    echo "Error: engine has no lib/dxmt" >&2
    exit 1
  }
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

echo "==> Step 2.3: Runtime settings..."
wine_reg() {
  WINEPREFIX="$WINEPREFIX" arch -x86_64 "$ENGINE_DIR/bin/wine" reg add "$@" >/dev/null
}
wine_reg "HKEY_CURRENT_USER\Software\Wine\Drivers" /v Graphics /t REG_SZ /d mac /f
wine_reg "HKEY_CURRENT_USER\Software\Wine\Mac Driver" /v AllowSetGamma /t REG_DWORD /d 0 /f
wine_reg "HKEY_CURRENT_USER\Software\Wine\Mac Driver" /v RetinaMode /t REG_SZ /d "$RETINA_MODE" /f

# Renderer DLLs deliberately get no registry overrides here. cxcompatdb
# selects their backend directory before Wine resolves those modules.
wine_reg "HKEY_CURRENT_USER\Software\Wine\DllOverrides" /v "winemenubuilder.exe" /t REG_SZ /d "" /f

# d3d10 gets a per-app (not global) override, scoped to the game's own exe:
# GPTK's own d3d10.dll (when present) trips a save-game hang (see
# docs/d3dmetal-savegame-crash.md); this pins d3d10 at Wine's own genuine,
# independent implementation instead of leaving resolution to chance. Applies
# to D3DMetal. The game never calls D3D10CreateDevice; D3DX11's internal
# D3D10CreateBlob dependency only needs Wine's implementation to resolve.
if is_d3dmetal_family "$GRAPHICS_BACKEND"; then
  EXE_BASENAME="$(basename "$EXE_REL_PATH")"
  wine_reg "HKEY_CURRENT_USER\Software\Wine\AppDefaults\\$EXE_BASENAME\DllOverrides" \
    /v d3d10 /t REG_SZ /d builtin /f
  echo "  Added d3d10=builtin override for $EXE_BASENAME"
fi

if [[ "$RUNTIME_MODE" == "verbs" ]]; then
  echo "==> Step 2.4: Installing DirectX/VC++ components with winetricks..."
  WINETRICKS_PATH="$(resolve_winetricks)" || {
    echo "Error: winetricks unavailable. Re-run setup and select redist fallback." >&2
    exit 1
  }
  mkdir -p "$APP_SUPPORT/cache/winetricks/downloads"
  run_winetricks "$WINETRICKS_PATH" -q \
    d3dx9_43 d3dx11_43 d3dcompiler_43 d3dcompiler_47 \
    vcrun2022 win10 sound=coreaudio
  missing_override=0
  for dll in d3dx9_43 d3dx11_43 d3dcompiler_43 d3dcompiler_47 \
             concrt140 msvcp140 vcruntime140; do
    if ! WINEPREFIX="$WINEPREFIX" arch -x86_64 "$ENGINE_DIR/bin/wine" reg query \
      "HKEY_CURRENT_USER\Software\Wine\DllOverrides" /v "*$dll" >/dev/null 2>&1; then
      echo "Error: winetricks did not register expected override: *$dll" >&2
      missing_override=1
    fi
  done
  [[ "$missing_override" -eq 0 ]] || {
    echo "Error: verbs installation completed without its required overrides." >&2
    echo "Use redist fallback only if you explicitly want the fallback policy." >&2
    exit 1
  }
else
  echo "==> Step 2.4: Installing bundled DirectX/VC++ redistributables..."
  REDIST_DIR="$ENGINE_DIR/share/gamma/redist"
  [[ -d "$REDIST_DIR" ]] || REDIST_DIR="$ENGINE_DIR/redist"
  [[ -d "$REDIST_DIR" ]] || REDIST_DIR="$REPO_ROOT/runtime/redist"
  SYS64="$WINEPREFIX/drive_c/windows/system32"
  # 64-bit only: the redist payload is grouped one subdirectory per package
  # (d3dcompiler_47/, directx_Jun2010_redist/, vcrun2022/, ...), each holding
  # an x86_64-windows/*.dll set confirmed required against xray-monolith.
  shopt -s nullglob
  REDIST_DLLS=("$REDIST_DIR"/*/x86_64-windows/*.dll)
  shopt -u nullglob
  [[ ${#REDIST_DLLS[@]} -gt 0 ]] || {
    echo "Error: bundled redist payload is missing" >&2
    exit 1
  }
  cp -f "${REDIST_DLLS[@]}" "$SYS64/"
  for dll_path in "${REDIST_DLLS[@]}"; do
    dll_name="$(basename "$dll_path" .dll)"
    wine_reg "HKEY_CURRENT_USER\Software\Wine\DllOverrides" /v "*$dll_name" /t REG_SZ /d "native,builtin" /f
  done
  WINEPREFIX="$WINEPREFIX" arch -x86_64 "$ENGINE_DIR/bin/wine" \
    "$ENGINE_DIR/lib/wine/x86_64-windows/winecfg.exe" -v win10
  wine_reg "HKEY_CURRENT_USER\Software\Wine\Drivers" /v Audio /t REG_SZ /d coreaudio /f
fi

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

# D3DMetal needs its framework and shared library located explicitly. Only
# export them for D3DMetal; forcing them during a DXMT run points the process
# at the wrong renderer.
case "\$GAMMA_GRAPHICS_BACKEND" in
  d3dmetal)
    if [[ -f "\$ENGINE_DIR/lib64/apple_gptk/external/libd3dshared.dylib" ]]; then
      export CX_APPLEGPTK_LIBD3DSHARED_PATH="\$ENGINE_DIR/lib64/apple_gptk/external/libd3dshared.dylib"
    fi
    if [[ -d "\$ENGINE_DIR/lib64/apple_gptk/external/D3DMetal.framework" ]]; then
      export CX_D3DMETALPATH="\$ENGINE_DIR/lib64/apple_gptk/external/D3DMetal.framework"
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
APP_SUPPORT="$APP_SUPPORT"
export WINEPREFIX="$WINEPREFIX"

if [[ ! -x "\$ENGINE_DIR/bin/wine" || ! -x "\$ENGINE_DIR/bin/wineserver" ]]; then
  echo "error: bundled Wine engine is incomplete: \$ENGINE_DIR" >&2
  exit 1
fi

WINETRICKS_BIN="\${WINETRICKS_BIN:-}"
if [[ -z "\$WINETRICKS_BIN" ]]; then
  for candidate in \
    "\$APP_SUPPORT/cache/winetricks/winetricks" \
    /opt/homebrew/bin/winetricks \
    /usr/local/bin/winetricks; do
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
export W_CACHE="\$APP_SUPPORT/cache/winetricks/downloads"
export PATH="\$WRAP_DIR:\$PATH"

echo "engine:     \$ENGINE_DIR"
echo "prefix:     \$WINEPREFIX"
echo "winetricks: \$WINETRICKS_BIN \$*"
echo

status=0
"\$WINETRICKS_BIN" "\$@" || status=\$?
exit "\$status"
EOF

cat > "$APP_PATH/Contents/MacOS/winecfg" << EOF
#!/usr/bin/env bash
# Opens winecfg for this app's prefix with its bundled Wine engine.
set -euo pipefail

APP_DIR="\$(cd "\$(dirname "\$0")/../.." && pwd)"
ENGINE_DIR="\$APP_DIR/Contents/Resources/engine"
APP_SUPPORT="$APP_SUPPORT"
CONFIG_FILE="\$APP_SUPPORT/app.env"
export WINEPREFIX="$WINEPREFIX"

if [[ ! -x "\$ENGINE_DIR/bin/wine" || \
      ! -f "\$ENGINE_DIR/lib/wine/x86_64-windows/winecfg.exe" ]]; then
  echo "error: bundled Wine engine has no winecfg: \$ENGINE_DIR" >&2
  exit 1
fi

if [[ -f "\$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "\$CONFIG_FILE"
fi
export GAMMA_GRAPHICS_BACKEND="\${GAMMA_GRAPHICS_BACKEND:-d3dmetal}"

echo "engine: \$ENGINE_DIR"
echo "prefix: \$WINEPREFIX"
echo

exec arch -x86_64 "\$ENGINE_DIR/bin/wine" \
  "\$ENGINE_DIR/lib/wine/x86_64-windows/winecfg.exe" "\$@"
EOF

# Small GUI over app.env: reads the user's actual settings file (never the
# template), renders each variable as a checkbox/field grouped the same way
# the template groups them, and writes straight back on every change (no
# Save button). Line-surgery only — every comment, blank line, and unknown
# export/#export the tool doesn't render is left byte-identical.
cat > "$APP_PATH/Contents/MacOS/configurator" << 'PYEOF'
#!/usr/bin/env python3
import re
import sys

CONFIG_FILE = "__GAMMA_CONFIG_FILE__"

try:
    from PySide6.QtWidgets import (
        QApplication, QWidget, QVBoxLayout, QHBoxLayout, QScrollArea,
        QGroupBox, QFormLayout, QCheckBox, QLineEdit, QComboBox, QPlainTextEdit,
    )
except ImportError:
    sys.stderr.write(
        "gamma-configurator: PySide6 not found. Install it with: pip3 install PySide6\n"
    )
    sys.exit(1)

# (section, KEY, kind, always_on). kind: bool | text | multiline | backend | retina.
# always_on vars are never commented out — only their value changes. The rest
# are "commentToggle": a checkbox adds/removes the leading '#', and the field's
# last-typed value is kept even while disabled so re-enabling restores it.
SCHEMA = [
    ("Core", "GAMMA_GRAPHICS_BACKEND", "backend", True),
    ("Core", "MTL_HUD_ENABLED", "bool", True),
    ("Core", "WINEMSYNC", "bool", True),
    ("Core", "WINEESYNC", "bool", True),
    ("Core", "ROSETTA_ADVERTISE_AVX", "bool", True),
    ("Core", "WINEDEBUG", "text", True),
    ("Core", "DEFAULT_GAME_ARGS", "text", True),
    ("Core", "GAMMA_RETINA_MODE", "retina", True),
    ("Core", "GAMMA_RETINA_LOGPIXELS", "text", False),
    ("D3DMetal (proven)", "D3DM_ENABLE_METALFX", "bool", True),
    ("D3DMetal (proven)", "D3DM_MAX_FPS", "text", True),
    ("D3DMetal (proven)", "D3DM_POSITION_INVARIANCE", "bool", True),
    ("D3DMetal (proven)", "D3DM_SAMPLE_NAN_TO_ZERO", "bool", True),
    ("D3DMetal (proven)", "D3DM_FLUSH_POS_INF_TO_NAN", "bool", True),
    ("D3DMetal (untested)", "D3DM_SHOW_HUD_STATS", "text", False),
    ("D3DMetal (untested)", "D3DM_LOD_BIAS", "text", False),
    ("D3DMetal (untested)", "D3DM_MIN_LOD_CLAMP", "text", False),
    ("D3DMetal (untested)", "D3DM_SUPPORT_DXR", "text", False),
    ("D3DMetal (untested)", "D3DM_MTL4", "text", False),
    ("D3DMetal (untested)", "D3DM_IGNORE_D3D11_RENDER_BARRIERS", "text", False),
    ("D3DMetal (untested)", "D3DM_BOUNDS_CHECK", "text", False),
    ("D3DMetal (untested)", "D3DM_ERROR_MODE", "text", False),
    ("D3DMetal (untested)", "D3DM_LOGLEVEL_INFO", "text", False),
    ("D3DMetal (untested)", "D3DM_NVNGX_PATH", "text", False),
    ("D3DMetal (untested)", "D3DM_VENDOR_ID", "text", False),
    ("D3DMetal (untested)", "D3DM_DEVICE_ID", "text", False),
    ("D3DMetal (untested)", "D3DM_DEVICE_DESCRIPTION", "text", False),
    ("D3DMetal (untested)", "D3DM_DEVICE_REVISION", "text", False),
    ("D3DMetal (untested)", "D3DM_DEVICE_SUBSYS", "text", False),
    ("DXMT", "DXMT_METALFX_SPATIAL_SWAPCHAIN", "bool", True),
    ("DXMT", "DXMT_LOG_LEVEL", "text", False),
    ("DXMT", "DXMT_LOG_PATH", "text", False),
    ("DXMT", "DXMT_SHADER_CACHE", "text", False),
    ("DXMT", "DXMT_SHADER_CACHE_PATH", "text", False),
    ("DXMT", "DXMT_CAPTURE_FRAME", "text", False),
    ("DXMT", "DXMT_CAPTURE_EXECUTABLE", "text", False),
    ("DXMT", "DXMT_CONFIG", "multiline", False),
    ("DXMT", "DXMT_CONFIG_FILE", "text", False),
]

# Matches "export KEY=VALUE" or "#export KEY=VALUE", with an optional
# trailing comment separated by 2+ spaces (this file's own convention).
LINE_RE = re.compile(r'^(?P<hash>#)?export\s+(?P<key>\w+)=(?P<value>.*?)(?P<tail>\s{2,}#.*)?$')


def read_lines(path):
    with open(path, "r") as f:
        return f.readlines()


def find_line(lines, key):
    for i, line in enumerate(lines):
        m = LINE_RE.match(line.rstrip("\n"))
        if m and m.group("key") == key:
            return i, m
    return None, None


def read_value(lines, key):
    _, m = find_line(lines, key)
    if not m:
        return False, ""
    return m.group("hash") is None, m.group("value")


def write_value(path, lines, key, active, value):
    i, m = find_line(lines, key)
    if m is None:
        return
    tail = m.group("tail") or ""
    lines[i] = ("" if active else "#") + "export " + key + "=" + value + tail + "\n"
    with open(path, "w") as f:
        f.writelines(lines)


class ConfiguratorWindow(QWidget):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("GAMMA Configurator")
        self.resize(560, 640)
        self.lines = read_lines(CONFIG_FILE)

        outer = QVBoxLayout(self)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        container = QWidget()
        vbox = QVBoxLayout(container)

        sections = {}
        for section, key, kind, always_on in SCHEMA:
            if section not in sections:
                box = QGroupBox(section)
                box.setLayout(QFormLayout())
                sections[section] = box
                vbox.addWidget(box)
            sections[section].layout().addRow(key, self._build_row(key, kind, always_on))

        vbox.addStretch(1)
        scroll.setWidget(container)
        outer.addWidget(scroll)

    def _build_row(self, key, kind, always_on):
        active, value = read_value(self.lines, key)

        if kind == "backend":
            combo = QComboBox()
            combo.addItems(["d3dmetal", "dxmt"])
            combo.setCurrentText(value if value in ("d3dmetal", "dxmt") else "d3dmetal")
            combo.currentTextChanged.connect(lambda text, k=key: self._save(k, True, text))
            return combo

        if kind == "retina":
            box = QCheckBox()
            box.setChecked(value.strip() == "Y")
            box.toggled.connect(lambda checked, k=key: self._save(k, True, "Y" if checked else "N"))
            return box

        if kind == "bool" and always_on:
            box = QCheckBox()
            box.setChecked(value.strip() == "1")
            box.toggled.connect(lambda checked, k=key: self._save(k, True, "1" if checked else "0"))
            return box

        row = QWidget()
        hbox = QHBoxLayout(row)
        hbox.setContentsMargins(0, 0, 0, 0)

        enable_box = None
        if not always_on:
            enable_box = QCheckBox()
            enable_box.setChecked(active)
            hbox.addWidget(enable_box)

        if kind == "multiline":
            field = QPlainTextEdit()
            field.setPlainText(value)
            field.setFixedHeight(60)
            field.setEnabled(always_on or active)
            field.textChanged.connect(
                lambda k=key, f=field, e=enable_box: self._save(
                    k, e.isChecked() if e else True, f.toPlainText()
                )
            )
        else:
            field = QLineEdit()
            field.setText(value)
            field.setEnabled(always_on or active)
            field.editingFinished.connect(
                lambda k=key, f=field, e=enable_box: self._save(
                    k, e.isChecked() if e else True, f.text()
                )
            )

        if enable_box is not None:
            enable_box.toggled.connect(
                lambda checked, k=key, f=field: (
                    f.setEnabled(checked),
                    self._save(k, checked, f.toPlainText() if isinstance(f, QPlainTextEdit) else f.text()),
                )
            )

        hbox.addWidget(field)
        return row

    def _save(self, key, active, value):
        write_value(CONFIG_FILE, self.lines, key, active, value)


def main():
    app = QApplication(sys.argv)
    window = ConfiguratorWindow()
    window.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
PYEOF
# Bake in this install's actual app.env path (may contain spaces, e.g.
# "Application Support" — sed with '#' delimiter avoids clashing with '/').
sed -i '' "s#__GAMMA_CONFIG_FILE__#$CONFIG_FILE#" "$APP_PATH/Contents/MacOS/configurator"

chmod +x \
  "$APP_PATH/Contents/MacOS/launcher" \
  "$APP_PATH/Contents/MacOS/winetricks" \
  "$APP_PATH/Contents/MacOS/winecfg" \
  "$APP_PATH/Contents/MacOS/configurator"

# 5. Ad-hoc sign the bundle. The engine payload is already signed by
#    pack-engine-artifact.sh, so only the wrapper needs a signature.
echo "==> Step 4: Signing bundle..."
codesign --force --sign - --timestamp=none "$APP_PATH/Contents/MacOS/launcher" 2>/dev/null || true
codesign --force --sign - --timestamp=none "$APP_PATH/Contents/MacOS/winetricks" 2>/dev/null || true
codesign --force --sign - --timestamp=none "$APP_PATH/Contents/MacOS/winecfg" 2>/dev/null || true
codesign --force --sign - --timestamp=none "$APP_PATH/Contents/MacOS/configurator" 2>/dev/null || true
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
echo "  Dependencies: $RUNTIME_MODE"
if is_d3dmetal_family "$GRAPHICS_BACKEND"; then
  echo "  GPTK:     4.0b2"
  echo "            d3d10.dll/.so excluded from payload, d3d10=builtin override"
  echo "            added for $(basename "$EXE_REL_PATH")"
fi
echo ""
echo "Launch via:  open \"$APP_PATH\""
echo "Or CLI:      \"$APP_PATH/Contents/MacOS/launcher\" -dbg -nointro"
echo "Winetricks:  \"$APP_PATH/Contents/MacOS/winetricks\" [verb ...]"
echo "WineCfg:     \"$APP_PATH/Contents/MacOS/winecfg\""
echo "Configurator:\"$APP_PATH/Contents/MacOS/configurator\"  (requires: pip3 install PySide6)"
echo "=========================================================="
