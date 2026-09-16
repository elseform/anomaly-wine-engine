# Manual Prefix Setup & Launch

`interactive_setup.py` (lives in `gamma-setup-tool`, see [README.md](../README.md)) automates everything below. This doc exists
for debugging the prefix by hand, or understanding what the script actually
does under the hood — it isn't a supported alternative entry point.

## Create & configure a prefix manually

### Step 1: Initialize Prefix

```bash
export WINE_DIR="$PWD/install/wine-cx26-x86_64"
export WINEPREFIX="$HOME/Library/Application Support/GAMMA/prefix"

# Clean prior server instance
arch -x86_64 "$WINE_DIR/bin/wineserver" -k 2>/dev/null || true
mkdir -p "$WINEPREFIX"

# Bootstrap
WINEPREFIX="$WINEPREFIX" arch -x86_64 "$WINE_DIR/bin/wine" wineboot -u
WINEPREFIX="$WINEPREFIX" arch -x86_64 "$WINE_DIR/bin/wineserver" -w
```

### Step 2: Configure Drive Mappings & User Profiles

```bash
# Drive C: and Z:
mkdir -p "$WINEPREFIX/dosdevices"
ln -sfn "/" "$WINEPREFIX/dosdevices/z:"
ln -sfn "../drive_c" "$WINEPREFIX/dosdevices/c:"

# Drive G: (pointing to your game installation folder)
ln -sfn "/path/to/your/game/install" "$WINEPREFIX/dosdevices/g:"

# User Profile Symlinks (pick any profile name you like)
mkdir -p "$WINEPREFIX/drive_c/users/<profile>"
ln -sfn "<profile>" "$WINEPREFIX/drive_c/users/crossover"
ln -sfn "<profile>" "$WINEPREFIX/drive_c/users/$USER"
```

### Step 3: Set Base Runtime Registry Values

```bash
WINEPREFIX="$WINEPREFIX" arch -x86_64 "$WINE_DIR/bin/wine" reg add "HKEY_CURRENT_USER\Software\Wine\Drivers" /v Graphics /t REG_SZ /d mac /f
WINEPREFIX="$WINEPREFIX" arch -x86_64 "$WINE_DIR/bin/wine" reg add "HKEY_CURRENT_USER\Software\Wine\DllOverrides" /v "winemenubuilder.exe" /t REG_SZ /d "" /f
```

Do not add renderer or helper-library overrides here. `cxcompatdb` selects the
renderer. The verbs in the next step install their native DLLs and create
their own overrides.

### Step 4: Install Winetricks Verbs

```bash
curl -fsSL https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks -o /tmp/winetricks
chmod +x /tmp/winetricks

WINE="$WINE_DIR/bin/wine" WINESERVER="$WINE_DIR/bin/wineserver" WINEPREFIX="$WINEPREFIX" \
  /tmp/winetricks -q \
  d3dx9_43 \
  d3dx11_43 \
  d3dcompiler_43 \
  d3dcompiler_47 \
  vcrun2022 \
  win10 \
  sound=coreaudio

WINEPREFIX="$WINEPREFIX" arch -x86_64 "$WINE_DIR/bin/wineserver" -w
```

## Launch the game manually

To run the game with full performance and DirectInput mouse capture:

```bash
export WINEPREFIX="$HOME/Library/Application Support/GAMMA/prefix"
export WINEMSYNC=1
export ROSETTA_ADVERTISE_AVX=1
export MTL_HUD_ENABLED=1

# Change to the game's bin directory so xrCore loads local DLLs
cd "/path/to/your/game/install/bin"

# Launch Anomaly
arch -x86_64 "$PWD/install/wine-cx26-x86_64/bin/wine" "G:\bin\AnomalyDX11AVX.exe" -dbg
```
