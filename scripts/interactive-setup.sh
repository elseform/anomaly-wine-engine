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

DXMT_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dxmt-only)
      DXMT_ONLY=1
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

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
  EXE_REL_PATH="$(prompt_path "Path to .exe, relative to game root" "sept/bin/AnomalyDX11.exe")"
  EXE_REL_PATH="${EXE_REL_PATH#/}"
  [[ -f "$GAMMA_ROOT/$EXE_REL_PATH" ]] && break
  echo "  Not found: $GAMMA_ROOT/$EXE_REL_PATH"
  read -r -p "  Use anyway? [y/N]: " force || true
  [[ "${force:-N}" =~ ^[Yy] ]] && break
done
EXE_WIN_PATH="G:\\${EXE_REL_PATH//\//\\}"
EXE_RUN_DIR="$GAMMA_ROOT/$(dirname "$EXE_REL_PATH")"

if [[ "$DXMT_ONLY" -eq 1 ]]; then
  GRAPHICS_BACKEND=dxmt
else
  echo ""
  echo "Graphics backend:"
  echo "  1) dxmt      DXMT — D3D11/10 via Metal (default, works for 32-bit too)"
  echo "  2) d3dmetal  Apple D3DMetal — D3D11/12 via Metal (64-bit only)"
  BACKEND_CHOICE="$(prompt_path "Select backend" "1")"
  case "$BACKEND_CHOICE" in
    1|dxmt)     GRAPHICS_BACKEND=dxmt ;;
    2|d3dmetal) GRAPHICS_BACKEND=d3dmetal ;;
    *)
      echo "  Unrecognized choice '$BACKEND_CHOICE', using dxmt"
      GRAPHICS_BACKEND=dxmt
      ;;
  esac
fi

if [[ "$DXMT_ONLY" -eq 1 ]]; then
  RUNTIME_MODE=redist
else
  echo ""
  echo "Runtime dependencies:"
  echo "  1) redist  Copy bundled DLLs and register fallback overrides (default)"
  echo "  2) verbs   Install required components with winetricks"
  RUNTIME_CHOICE="$(prompt_path "Select dependency source" "1")"
  case "$RUNTIME_CHOICE" in
    1|redist|dlls)      RUNTIME_MODE=redist ;;
    2|verbs|winetricks) RUNTIME_MODE=verbs ;;
    *)
      echo "  Unrecognized choice '$RUNTIME_CHOICE', using redist"
      RUNTIME_MODE=redist
      ;;
  esac
fi

RETINA_MODE=N

# cxcompatdb checks this on every wine invocation from here on (wineboot,
# reg add/query, winecfg — not just the final generated game launcher, whose
# own app.env-sourced export only takes effect after this script exits).
# Without it, cxcompatdb falls back to its own default (d3dmetal), which
# fails outright against a --dxmt-only engine artifact that has no
# lib64/apple_gptk payload at all.
export GAMMA_GRAPHICS_BACKEND="$GRAPHICS_BACKEND"

APP_SUPPORT="$HOME/Library/Application Support/$APP_NAME"
WINEPREFIX="$APP_SUPPORT/prefix"
ENGINE_DIR="$APP_PATH/Contents/Resources/engine"
CONFIG_FILE="$APP_SUPPORT/app.env"
STATE_FILE="$APP_SUPPORT/configurator-state.json"

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
# GPTK's own d3d10.dll (always present in the staged payload) trips a
# save-game hang (see docs/renderers.md); this pins d3d10 at Wine's own genuine,
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
# Minimal, backend-conditional seed — only the always-on vars for the chosen
# backend; every optional/untested var stays absent (Configurator's default =
# disabled). No inline comments: Configurator is the documented interface now
# (runtime/configurator/configurator.py's SCHEMA), this file is generated
# output. Keep this seed's var names/quoting in sync with that SCHEMA by hand
# — there is no automated check.
if [[ -f "$CONFIG_FILE" ]]; then
  echo "  Keeping existing settings: $CONFIG_FILE"
else
  {
    echo "# Edit via Contents/MacOS/configurator — see it for descriptions and valid ranges."
    echo ""
    echo "export GAMMA_GRAPHICS_BACKEND=$GRAPHICS_BACKEND"
    echo "export EXE_PATH='$EXE_WIN_PATH'"
    echo "export EXE_RUN_DIR='$EXE_RUN_DIR'"
    echo ""
    echo "export MTL_HUD_ENABLED=1"
    echo "export WINEMSYNC=1"
    echo "export WINEESYNC=1"
    echo "export ROSETTA_ADVERTISE_AVX=1"
    echo "export WINEDEBUG=\"-all\""
    echo "export DEFAULT_GAME_ARGS=\"\""
    echo "export GAMMA_RETINA_MODE=$RETINA_MODE"
    echo ""
    if is_d3dmetal_family "$GRAPHICS_BACKEND"; then
      echo "export D3DM_ENABLE_METALFX=0"
      echo "export D3DM_MAX_FPS=60"
      echo "export D3DM_POSITION_INVARIANCE=1"
      echo "export D3DM_SAMPLE_NAN_TO_ZERO=1"
      echo "export D3DM_FLUSH_POS_INF_TO_NAN=1"
    else
      echo "export DXMT_METALFX_SPATIAL_SWAPCHAIN=0"
      echo "export DXMT_ENABLE_NVEXT=0"
    fi
  } > "$CONFIG_FILE"
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

# NGX/DLSS shim files, per backend: D3DM_ENABLE_METALFX (D3DMetal) and
# DXMT_ENABLE_NVEXT (DXMT, gates dxgi.cpp's InitializeVendorExtensionNV)
# each additionally place their own backend's nvngx.dll (D3DMetal's is
# renamed from nvngx-on-metalfx by install-renderers.sh) and nvapi64.dll
# directly in the prefix's system32 — some NGX/DLSS detection paths check
# for the files there, not just Wine's own DLL search path (which already
# resolves them from lib64/apple_gptk or lib/dxmt via cxcompatdb regardless
# of these toggles). Whatever was already at those two names in system32
# gets backed up as <name>.old before being overwritten, and restored the
# moment neither toggle applies (backend switch or the toggle going back
# off); a name with no prior file is just removed again on disable.
GAMMA_NVNGX_SYSTEM32="\$WINEPREFIX/drive_c/windows/system32"
if [[ -d "\$GAMMA_NVNGX_SYSTEM32" ]]; then
  GAMMA_NVNGX_SRC_DIR=""
  case "\$GAMMA_GRAPHICS_BACKEND" in
    dxmt)
      if [[ "\${DXMT_ENABLE_NVEXT:-0}" == "1" ]]; then
        GAMMA_NVNGX_SRC_DIR="\$ENGINE_DIR/lib/dxmt/x86_64-windows"
      fi
      ;;
    d3dmetal)
      if [[ "\${D3DM_ENABLE_METALFX:-0}" == "1" ]]; then
        GAMMA_NVNGX_SRC_DIR="\$ENGINE_DIR/lib64/apple_gptk/wine/x86_64-windows"
      fi
      ;;
  esac
  if [[ -n "\$GAMMA_NVNGX_SRC_DIR" ]]; then
    for module in nvngx nvapi64; do
      src="\$GAMMA_NVNGX_SRC_DIR/\$module.dll"
      dst="\$GAMMA_NVNGX_SYSTEM32/\$module.dll"
      [[ -f "\$src" ]] || continue
      if [[ ! -f "\$dst.old" && -f "\$dst" ]]; then
        mv "\$dst" "\$dst.old"
      fi
      cp -f "\$src" "\$dst"
    done
  else
    for module in nvngx nvapi64; do
      dst="\$GAMMA_NVNGX_SYSTEM32/\$module.dll"
      if [[ -f "\$dst.old" ]]; then
        mv -f "\$dst.old" "\$dst"
      elif [[ -f "\$dst" ]]; then
        rm -f "\$dst"
      fi
    done
  fi
fi

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

# Native SwiftUI GUI over app.env: renders the schema (Schema.swift, ported
# from the former runtime/configurator/configurator.py) as toggles/fields
# grouped by section, keyed off a sidecar configurator-state.json (holds
# every var's value + enabled state regardless of current backend, so
# switching backends or re-enabling a var restores exactly what was typed
# before). app.env itself is pure generated output — no inline comments, no
# lines for the backend that isn't selected. Built by pack-engine-artifact.sh
# (scripts/build-configurator.sh) and shipped prebuilt inside the engine
# artifact (share/gamma/Configurator.app) — this script stays
# standalone/archive-only and never builds anything from source. It's a real
# nested .app bundle (not a loose binary) so it opens as a GUI window, not
# Terminal, when launched directly or via the "<app name> Configurator" alias
# (named to sort next to the main .app in Finder).
CONFIGURATOR_SRC="$ENGINE_DIR/share/gamma/Configurator.app"
[[ -d "$CONFIGURATOR_SRC" ]] || {
  echo "Error: Configurator.app is missing (expected in the engine artifact)" >&2
  exit 1
}
mkdir -p "$APP_PATH/Contents/Resources"
cp -R "$CONFIGURATOR_SRC" "$APP_PATH/Contents/Resources/Configurator.app"
mkdir -p "$APP_PATH/Contents/Resources/Configurator.app/Contents/Resources"
cat > "$APP_PATH/Contents/Resources/Configurator.app/Contents/Resources/paths.json" <<JSON
{"configFile": "$CONFIG_FILE", "stateFile": "$STATE_FILE"}
JSON

chmod +x \
  "$APP_PATH/Contents/MacOS/launcher" \
  "$APP_PATH/Contents/MacOS/winetricks" \
  "$APP_PATH/Contents/MacOS/winecfg"

# 5. Ad-hoc sign the bundle. The engine payload (and the Configurator.app
#    nested inside it) is already signed by pack-engine-artifact.sh; this
#    re-signs the wrapper scripts plus the whole bundle envelope so the
#    paths.json we just dropped in doesn't invalidate anything upstream.
echo "==> Step 4: Signing bundle..."
codesign --force --sign - --timestamp=none "$APP_PATH/Contents/MacOS/launcher" 2>/dev/null || true
codesign --force --sign - --timestamp=none "$APP_PATH/Contents/MacOS/winetricks" 2>/dev/null || true
codesign --force --sign - --timestamp=none "$APP_PATH/Contents/MacOS/winecfg" 2>/dev/null || true
codesign --force --sign - --timestamp=none "$APP_PATH/Contents/Resources/Configurator.app" 2>/dev/null || true
if codesign --force --sign - --timestamp=none "$APP_PATH" 2>/dev/null; then
  echo "  Ad-hoc signed $APP_PATH"
else
  echo "  Warning: could not sign the bundle (it will still run locally)" >&2
fi

echo "==> Step 5: Registering with Launch Services..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_PATH" 2>/dev/null || true

CONFIGURATOR_ALIAS_TARGET="$APP_PATH/Contents/Resources/Configurator.app"
CONFIGURATOR_ALIAS_NAME="$APP_NAME Configurator"
echo "==> Step 6: Creating \"$CONFIGURATOR_ALIAS_NAME\" alias..."
if [[ ! -e "$APP_DIR_PARENT/$CONFIGURATOR_ALIAS_NAME.app" ]]; then
  osascript <<OSA
tell application "Finder"
  set aliasFile to make new alias file at POSIX file "$APP_DIR_PARENT" to (POSIX file "$CONFIGURATOR_ALIAS_TARGET" as alias)
  set name of aliasFile to "$CONFIGURATOR_ALIAS_NAME"
end tell
OSA
else
  echo "  Skipping: $APP_DIR_PARENT/$CONFIGURATOR_ALIAS_NAME.app already exists"
fi

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
  echo "  GPTK:     staged by install-renderers.sh (--apple-gptk selects the version)"
  echo "            d3d10=builtin override added for $(basename "$EXE_REL_PATH")"
fi
echo ""
echo "Launch via:  open \"$APP_PATH\""
echo "Or CLI:      \"$APP_PATH/Contents/MacOS/launcher\" -dbg -nointro"
echo "Winetricks:  \"$APP_PATH/Contents/MacOS/winetricks\" [verb ...]"
echo "WineCfg:     \"$APP_PATH/Contents/MacOS/winecfg\""
echo "Configurator: double-click \"$CONFIGURATOR_ALIAS_NAME\" next to the app in $APP_DIR_PARENT"
echo "              or open \"$APP_PATH/Contents/Resources/Configurator.app\""
echo "=========================================================="
