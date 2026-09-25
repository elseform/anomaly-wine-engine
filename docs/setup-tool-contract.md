# Setup Tool Contract

What [gamma-setup-tool](https://github.com/elseform/gamma-setup-tool) relies on
in an engine archive, and what it builds from one. Anything listed here is an
interface: changing it needs a matching change in the setup tool.

The setup tool's `interactive_setup.py` does the work: it extracts the archive
into a new wrapper app, creates the Wine prefix, installs runtime dependencies
and writes the launcher.

## Archive

A `.tar.zst` (or `.tar.xz`) with a single top-level directory,
`wswine.bundle/`, which is stripped on extraction. Paths below are relative to
it.

### Required

| Path | Used for |
|---|---|
| `bin/wine`, `bin/wineserver` | Everything; `wine --version` must run |
| `lib/wine/x86_64-unix/cxcompatdb.so` | Presence check; selects the graphics backend at runtime |
| `lib/dxmt/` | The DXMT backend (for `--backend dxmt`) |
| `lib64/apple_gptk/wine/` | The D3DMetal backend (only for `--backend d3dmetal`) |
| `share/gamma/redist-manifest.json` | The Microsoft runtime files to install (`--runtime-mode redist`) |
| `share/gamma/redist-fetch/gamma_redist.py` | Imported by the setup script; must provide `load_manifest(path)`, `install(manifest, system32, cache_dir, search_dirs, log)` returning the installed DLL names, and `RedistError` |
| `share/gamma/Configurator.app` | Copied into the wrapper |

### Optional

| Path | Used for |
|---|---|
| `version` | First line becomes the wrapper's `CFBundleShortVersionString` |
| `lib64/apple_gptk/` | Its absence marks a DXMT-only engine |
| `engine-manifest.json` | Engine identity; not read by the setup tool yet |

### Used by the generated wrapper at runtime

| Path | Used by |
|---|---|
| `lib/wine/x86_64-windows/winecfg.exe` | The `winecfg` helper |
| `lib/dxmt/x86_64-windows/nvngx.dll`, `nvapi64.dll` | Copied into the prefix's `system32` when `DXMT_ENABLE_NVEXT=1` |
| `lib64/apple_gptk/external/libd3dshared.dylib`, `D3DMetal.framework` | The launcher, for `d3dmetal` only |

## Wrapper layout

```text
<App>.app/Contents/MacOS/launcher                    sources app.env, runs the game
<App>.app/Contents/MacOS/winetricks                  prefix-aware winetricks
<App>.app/Contents/MacOS/winecfg                     prefix-aware winecfg
<App>.app/Contents/Resources/engine/                 the extracted engine
<App>.app/Contents/Resources/Configurator.app        settings editor
<App>.app/Contents/Resources/configurator-paths.json where the Configurator finds app.env

~/Library/Application Support/<App>/prefix           Wine prefix
~/Library/Application Support/<App>/app.env          settings, sourced by the launcher
```

Settings and the prefix live outside the app so it can be replaced and
re-signed without losing them. The wrapper declares
`LSMinimumSystemVersion` 15.0.

## Settings (`app.env`)

`interactive_setup.py` writes the first `app.env`; after that the Configurator
owns it. The Configurator's schema (`runtime/configurator-gui/Sources/Schema.swift`)
and the setup script's seed must agree on key names and defaults. Current seed
for a DXMT wrapper:

```bash
export EXE_PATH='G:\...\AnomalyDX11.exe'
export EXE_RUN_DIR='/path/to/game/bin'
export GAMMA_GRAPHICS_BACKEND=dxmt
export WINEMSYNC=1
export WINEESYNC=1
export ROSETTA_ADVERTISE_AVX=0
export GAMMA_RETINA_MODE=N
export MTL_HUD_ENABLED=0
export WINEDEBUG="-all"
export DEFAULT_GAME_ARGS=""
export DXMT_METALFX_SPATIAL_SWAPCHAIN=0
export DXMT_ENABLE_NVEXT=1
export DXMT_CONFIG="d3d11.sampleNaNToZero=true;"
```

The Configurator keeps a disabled setting's value as a commented line
(`#export KEY=VALUE`), so `app.env` alone carries every setting.

## Configurator paths file

The setup script writes `{"configFile", "stateFile", "dxmtOnly"}` to
`Contents/Resources/configurator-paths.json` in the wrapper, and the same
content to `Configurator.app/Contents/Resources/paths.json` for older
Configurator builds. The Configurator also works without either, from
`~/Library/Application Support/<App name>/app.env`. `stateFile` is only read to
migrate installs from before `app.env` became the Configurator's only store.
`dxmtOnly` is still accepted but no longer read: the Configurator offers only
DXMT.

## Versioning

The archive carries `engine-manifest.json` with `engineId`, `versionLabel`,
`buildNumber`, `base`, `minimumMacOS` and `minimumSetupToolVersion`; the
`.manifest.json` sidecar adds `artifact` and `artifactSHA256`. The setup tool
does not check any of these yet, so compatibility is kept by not removing or
renaming anything in this document.
