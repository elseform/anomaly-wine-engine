#!/usr/bin/env bash
# Interactive setup: builds a macOS .app around the packaged Wine engine.
#
# Bundle layout:
#   <App>.app/Contents/MacOS/launcher        thin launcher, paths baked in
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
echo "  4) wined3d   Wine's OpenGL renderer (fallback)"
echo "  5) default   Let the engine pick (d3dmetal, then dxmt, then wined3d)"
BACKEND_CHOICE="$(prompt_path "Select backend" "1")"
case "$BACKEND_CHOICE" in
  1|d3dmetal) GRAPHICS_BACKEND=d3dmetal ;;
  2|dxmt)     GRAPHICS_BACKEND=dxmt ;;
  3|dxvk)     GRAPHICS_BACKEND=dxvk ;;
  4|wined3d)  GRAPHICS_BACKEND=wined3d ;;
  5|default)  GRAPHICS_BACKEND=default ;;
  *)
    echo "  Unrecognized choice '$BACKEND_CHOICE', using d3dmetal"
    GRAPHICS_BACKEND=d3dmetal
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

ENGINE_VERSION="$(head -n 1 "$ENGINE_DIR/version" 2>/dev/null || echo "1.0.0")"

# Warn early when the selected backend is not actually present in the engine.
case "$GRAPHICS_BACKEND" in
  d3dmetal) [[ -d "$ENGINE_DIR/lib/d3dmetal" ]] || echo "  Warning: engine has no lib/d3dmetal" >&2 ;;
  dxmt)     [[ -d "$ENGINE_DIR/lib/dxmt" ]] || echo "  Warning: engine has no lib/dxmt" >&2 ;;
  dxvk)
    [[ -d "$ENGINE_DIR/lib/dxvk" ]] || echo "  Warning: engine has no lib/dxvk" >&2
    if [[ ! -f "$ENGINE_DIR/lib/wine/x86_64-unix/libMoltenVK.dylib" &&
          ! -f "$ENGINE_DIR/lib64/libMoltenVK.dylib" ]]; then
      echo "  Warning: engine has no libMoltenVK.dylib — DXVK will fall back to wined3d" >&2
    fi
    ;;
esac

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
for dll in "*d3dcompiler_47" "*d3dx9_43" "*d3dx10_43" "*d3dx11_43" \
           "*concrt140" "*msvcp140" "*msvcp140_1" "*msvcp140_2" \
           "*msvcp140_atomic_wait" "*msvcp140_codecvt_ids" \
           "*vcamp140" "*vccorlib140" "*vcomp140" "*vcruntime140" "*vcruntime140_1"; do
  wine_reg "HKEY_CURRENT_USER\Software\Wine\DllOverrides" /v "$dll" /t REG_SZ /d "native,builtin" /f
done
wine_reg "HKEY_CURRENT_USER\Software\Wine\DllOverrides" /v "winemenubuilder.exe" /t REG_SZ /d "" /f

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
  cat > "$CONFIG_FILE" << EOF
# $APP_NAME runtime configuration — edit freely, no rebuild needed.
# Sourced by the launcher on every start, before its own defaults, so
# anything set here wins. Backend that activated: check stderr for
# "gamma-cxcompatdb:info: graphics backend=... path=..." (survives WINEDEBUG=-all).

# --- Backend --- d3dmetal | dxmt | dxvk | wined3d | default
export GAMMA_GRAPHICS_BACKEND=$GRAPHICS_BACKEND

# --- General ---
export EXE_PATH='$EXE_WIN_PATH'          # Windows path launched by Wine
export EXE_RUN_DIR='$EXE_RUN_DIR'        # keep in sync with EXE_PATH's dir
export MTL_HUD_ENABLED=1                 # Metal perf HUD             0 | 1
export WINEMSYNC=1                       # Darwin Mach semaphore sync 0 | 1
export WINEESYNC=0                       #                            0 | 1
export ROSETTA_ADVERTISE_AVX=1           #                            0 | 1
export WINEDEBUG="-all"                  # "fixme-all" middle ground
export DEFAULT_GAME_ARGS=""              # used only with no CLI args

# --- Retina / HiDPI (Wine Mac Driver, CrossOver's Retina toggle) ---
export GAMMA_RETINA_MODE=$RETINA_MODE    # Y | N — synced every launch
#export GAMMA_RETINA_LOGPIXELS=          # DPI, e.g. 216/254 — needs Y

# --- D3DMetal (GAMMA_GRAPHICS_BACKEND=d3dmetal) ---
export D3DM_ENABLE_METALFX=0             # MetalFX upscaling          0 | 1
export D3DM_MAX_FPS=60                   # frame cap                 fps
#export D3DM_SHOW_HUD_STATS=1            # D3DMetal's own HUD         0 | 1
#export D3DM_LOD_BIAS=-0.5               # texture LOD bias           float
#export D3DM_MIN_LOD_CLAMP=0             # texture LOD floor          float
#export D3DM_SUPPORT_DXR=1               # advertise DXR raytracing   0 | 1
#export D3DM_MTL4=1                      # use Metal 4 backend path   0 | 1
export D3DM_POSITION_INVARIANCE=1        # fixes z-fighting/shimmer   0 | 1
export D3DM_SAMPLE_NAN_TO_ZERO=1         # clamp NaN texels to 0      0 | 1
export D3DM_FLUSH_POS_INF_TO_NAN=1       # float-edge-case fixup      0 | 1
#export D3DM_IGNORE_D3D11_RENDER_BARRIERS=1  # faster, can corrupt    0 | 1
#export D3DM_BOUNDS_CHECK=1              # debug bounds checking      0 | 1
#export D3DM_ERROR_MODE=1                # strictness on API misuse  integer
#export D3DM_LOGLEVEL_INFO=1             # verbose D3DMetal logging   0 | 1
#export D3DM_NVNGX_PATH=                 # dir with NVNGX/DLSS files  path
#export D3DM_VENDOR_ID=0x10de            # spoof GPU vendor    0x10de NVIDIA, 0x1002 AMD, 0x8086 Intel
#export D3DM_DEVICE_ID=0x2684            # spoof GPU device id        hex
#export D3DM_DEVICE_DESCRIPTION="NVIDIA GeForce RTX 4090"  # spoof GPU name
#export D3DM_DEVICE_REVISION=0           # spoof PCI revision        integer
#export D3DM_DEVICE_SUBSYS=0             # spoof PCI subsystem id    integer

# --- DXMT (GAMMA_GRAPHICS_BACKEND=dxmt) ---
export DXMT_METALFX_SPATIAL_SWAPCHAIN=0  # MetalFX spatial upscaling  0 | 1
#export DXMT_LOG_LEVEL=info              # trace|debug|info|warn|error
#export DXMT_LOG_PATH=                   # log file dir               path
#export DXMT_SHADER_CACHE=1              # persist compiled shaders   0 | 1
#export DXMT_SHADER_CACHE_PATH=          # cache dir                  path
#export DXMT_CAPTURE_FRAME=              # frame index to capture    integer
#export DXMT_CAPTURE_EXECUTABLE=         # only capture this exe      name
# Fine-grained: DXMT_CONFIG (semicolon list) or DXMT_CONFIG_FILE (key=value lines).
#export DXMT_CONFIG="d3d11.metalSpatialUpscaleFactor=1.0;d3d11.preferredMaxFrameRate=60;d3d11.sampleNaNToZero=true;dxgi.handleAltTab=true;d3d11.defuseFma=true;d3d11.maxFeatureLevel=11_1"
#export DXMT_CONFIG_FILE=
# Keys: d3d11.metalSpatialUpscaleFactor float(1.0=off) | d3d11.preferredMaxFrameRate fps
#       d3d11.maxFeatureLevel 10_0|10_1|11_0|11_1|12_0|12_1 | d3d11.defuseFma true|false
#       d3d11.ignoreMapFlagNoWait true|false | d3d11.sampleNaNToZero true|false
#       d3d11.loH | dxmt.shaderMetalVersion | dxgi.customVendorId hex
#       dxgi.customDeviceId hex | dxgi.customDeviceDesc string
#       dxgi.forceSDR true|false | dxgi.handleAltTab true|false
EOF
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
# export them when D3DMetal can actually be selected: cxcompatdb.so sets
# CX_APPLEGPTK_LIBD3DSHARED_PATH itself once a backend is active, and forcing
# these for a DXMT or DXVK run points the process at the wrong renderer.
case "\$GAMMA_GRAPHICS_BACKEND" in
  d3dmetal | default)
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

chmod +x "$APP_PATH/Contents/MacOS/launcher"

# 5. Ad-hoc sign the bundle. The engine payload is already signed by
#    pack-engine-artifact.sh, so only the wrapper needs a signature.
echo "==> Step 4: Signing bundle..."
codesign --force --sign - --timestamp=none "$APP_PATH/Contents/MacOS/launcher" 2>/dev/null || true
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
echo ""
echo "Launch via:  open \"$APP_PATH\""
echo "Or CLI:      \"$APP_PATH/Contents/MacOS/launcher\" -dbg -nointro"
echo "=========================================================="
