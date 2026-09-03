# gamma-wine-engine

**Custom, high-performance Wine 11.0 / CrossOver 26.3.0 engine tailored for S.T.A.L.K.E.R. Anomaly & G.A.M.M.A. on Apple Silicon (macOS).**

---

## Overview

`gamma-wine-engine` provides a standalone, relocatable Wine 11 runtime and packages the production `wswine.bundle` tarball (named `<artifactBasename>-<N>.tar.zst`, derived from `config/engine-version.txt` by `gamma_engine_artifact_basename` in `scripts/engine-common.sh` — e.g. `CX26W11-Gamma087-2.tar.zst`; see [Versioning Policy](docs/versioning-policy.md)) used by `gamma-setup-tool`.

### Documentation

| Doc | For |
|---|---|
| [Getting Started](docs/getting-started.md) | Build the `.app`, run it, change its settings |
| [How This Repo Works](docs/architecture.md) | Pipeline, scripts, patches, conventions |
| [Graphics Backends](docs/renderers.md) | Renderer layout, switching, and fallback behavior |
| [Patch Set](patches/README.md) | What each patch does and why one is excluded |
| [Why deps build from source](docs/why-no-prebuilt-deps.md) | The `.brew-x86` situation |
| [Versioning Policy](docs/versioning-policy.md) | Version-label / artifact-basename format, when to bump, CX/Wine base bumps |

### Key Features:
- **Base Runtime**: CrossOver 26.3.0 built on **Wine 11.0** (`x86_64` under Rosetta 2 on Apple Silicon).
- **Switchable Graphics Backends**: D3DMetal and DXMT ship side by side using CrossOver's directory convention; WineD3D remains an internal fallback. See [docs/renderers.md](docs/renderers.md).
  - **Apple D3DMetal (GPTK 4.0b2)**: Default for 64-bit Direct3D 11/12 via Metal.
  - **DXMT**: Selectable D3D11/10 via Metal, and the only Metal backend for 32-bit processes.
- **Dynamic Backend Switcher (`cxcompatdb.so`)**: Intercepts process startup and prepends the selected backend to the DLL search path — `GAMMA_GRAPHICS_BACKEND=d3dmetal|dxmt`, with no DLL file modifications in the prefix.
- **Darwin Mach Semaphore Sync (`WINEMSYNC=1`)**: In-process shared memory thread synchronization, eliminating wineserver IPC overhead and micro-stuttering across X-Ray Engine's worker threads.
- **Engine-Level Stability Patches**:
  - `win32u.so`: Stock upstream message-wait loop (the legacy MapleStory handoff hack is deliberately not applied), preventing UI/menu click deadlocks.
  - `ntdll.so`: Hardware memory barrier in `NtFlushProcessWriteBuffers` avoiding expensive Mach register queries that cause thread stalls under Rosetta 2.
- **Self-Contained Portability**: All runtime dependencies (`gnutls`, `freetype`, `libpng`, `zlib`, `gettext`, `libunistring`) are bundled with `@loader_path` relative linking.

---

## Engine Locations

| Type | Path | Purpose |
|---|---|---|
| **Development Staging Tree** | `install/wine-cx26-x86_64/` | Live uncompressed build tree (`bin/wine`, `bin/wineserver`, `lib/dxmt/`, `lib64/apple_gptk/`) |
| **Packaged Release Tarball** | `dist/artifacts/<artifactBasename>-<N>.tar.zst` — basename derived from `config/engine-version.txt`, e.g. `CX26W11-Gamma087-2.tar.zst` | Codesigned, stripped, standalone production archive |
| **Setup Tool Asset** | `gamma-setup-tool/sources/GAMMASetupTool/Resources/wine-engine/CX26-3W11-Gamma0-1.tar.xz` | Bundled asset embedded in `GAMMA Setup Tool.app` — copied in manually, so it lags the latest `dist/artifacts/` build; check its filename against `config/engine-version.txt` before assuming it's current |

---

## Dedicated Scripts

### 1. Interactive Setup (`scripts/interactive-setup.sh`)
Builds a fully self-contained `.app` from an engine `.tar.zst` (or explicit legacy `.tar.xz`): extracts the engine, bootstraps a
prefix, installs dependencies through winetricks by default (or bundled redist as an explicit
fallback), and writes the bundle metadata, launcher, prefix-aware `winetricks`, and `winecfg`
helpers. Standalone — calls no other repo script.
The generated `app.env` also exposes `EXE_PATH` and `EXE_RUN_DIR`, so the target can be changed
later without rebuilding the app.
```bash
bash scripts/interactive-setup.sh
```

### 2. Build Wine (`scripts/build-wine.sh`)
Full engine build: extracts sources, applies `patches/`, configures and builds CrossOver Wine for
`x86_64`, then chains `build-cxcompatdb.sh`, `bundle-wine-dylibs.sh`, and
`install-renderers.sh`.
```bash
bash scripts/build-wine.sh --cx 26 --without-vulkan
```

### 3. Package Release Artifact (`scripts/pack-engine-artifact.sh`)
Stages, strips, re-bundles dylibs, codesigns, scans minOS, and packs the install tree into
`dist/artifacts/`, writing the release manifest alongside it.
```bash
bash scripts/pack-engine-artifact.sh --force
```

## How to Create & Configure a New Prefix Manually

If you wish to create a custom prefix without the script, follow these steps:

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
ln -sfn "$HOME/gamma" "$WINEPREFIX/dosdevices/g:"

# User Profile Symlinks
mkdir -p "$WINEPREFIX/drive_c/users/Sikarugir"
ln -sfn "Sikarugir" "$WINEPREFIX/drive_c/users/crossover"
ln -sfn "Sikarugir" "$WINEPREFIX/drive_c/users/$USER"
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

---

## How to Launch the Game Manually

To run the game with full performance and DirectInput mouse capture:

```bash
export WINEPREFIX="$HOME/Library/Application Support/GAMMA/prefix"
export WINEMSYNC=1
export ROSETTA_ADVERTISE_AVX=1
export MTL_HUD_ENABLED=1

# Change to the game's bin directory so xrCore loads local DLLs
cd "$HOME/gamma/3dss5/bin"

# Launch Anomaly
arch -x86_64 "$PWD/install/wine-cx26-x86_64/bin/wine" "G:\3dss5\bin\AnomalyDX11AVX.exe" -dbg
```

---

## Build & Maintenance Commands

- **Build Wine from Source**:
  ```bash
  bash scripts/build-wine.sh --cx 26 --without-vulkan
  ```
- **Install Renderers (D3DMetal + DXMT)** — chained automatically by `build-wine.sh`
  (skip with `--skip-renderers`); run standalone to re-stage them:
  ```bash
  bash scripts/install-renderers.sh install/wine-cx26-x86_64
  ```
- **Fetch latest DXMT build**:
  ```bash
  bash scripts/fetch-dxmt.sh
  ```
- **Package Release Archive**:
  ```bash
  bash scripts/pack-engine-artifact.sh --force
  ```
