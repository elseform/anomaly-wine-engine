# Setup Tool Contract

What [anomaly-setup-tool](https://github.com/elseform/anomaly-setup-tool) relies on
in an engine archive, and what it builds from one. Anything listed here is an
interface: changing it needs a matching change in the setup tool.

The setup tool's `interactive_setup.py` does the work: it extracts the archive
into a new wrapper app, creates the Wine prefix, installs runtime dependencies
and writes the launcher.

## Archive

A `.tar.xz` with a single top-level directory (anomaly-setup-tool no longer accepts `.tar.zst`),
`wswine.bundle/`, which is stripped on extraction. Paths below are relative to
it.

### Required

| Path | Used for |
|---|---|
| `bin/wine`, `bin/wineserver` | Everything; `wine --version` must run |
| `lib/wine/x86_64-unix/cxcompatdb.so` | Presence check; selects the graphics backend at runtime |
| `lib/dxmt/` | The DXMT backend (for `--backend dxmt`) |
| `share/anomaly/redist-manifest.json` | The Microsoft runtime files to install (`--runtime-mode redist`) |
| `share/anomaly/redist-fetch/anomaly_redist.py` | Imported by the setup script; must provide `load_manifest(path)`, `install(manifest, system32, cache_dir, search_dirs, log)` returning the installed DLL names, and `RedistError` |

### Optional

| Path | Used for |
|---|---|
| `version` | First line becomes the wrapper's `CFBundleShortVersionString` |
| `engine-manifest.json` | Engine identity; not read by the setup tool yet |

### Used by the generated wrapper at runtime

| Path | Used by |
|---|---|
| `lib/wine/x86_64-windows/winecfg.exe` | The `winecfg` helper |
| `lib/dxmt/x86_64-windows/nvngx.dll`, `nvapi64.dll` | Copied into the prefix's `system32` when `DXMT_ENABLE_NVEXT=1` |

## Wrapper layout

```text
<App>.app/Contents/MacOS/AnomalyLauncher               native settings and launch UI
<App>.app/Contents/MacOS/launcher                    sources app.env, runs the target
<App>.app/Contents/MacOS/winetricks                  prefix-aware winetricks
<App>.app/Contents/MacOS/winecfg                     prefix-aware winecfg
<App>.app/Contents/Resources/engine/                 the extracted engine
<App>.app/Contents/Resources/Anomaly.icns              icon fallback
<App>.app/Contents/Resources/Assets.car              compiled Anomaly icon appearances
<App>.app/Contents/Resources/configurator-paths.json where the native launcher finds app.env

~/Library/Application Support/<App>/prefix           Wine prefix
~/Library/Application Support/<App>/app.env          settings, sourced by the launcher
```

Settings and the prefix live outside the app so it can be replaced and
re-signed without losing them. The wrapper declares
`LSMinimumSystemVersion` 26.0.

## Settings (`app.env`)

`interactive_setup.py` writes the first `app.env`; after that the native wrapper UI
owns it. Its schema (`sources/AnomalyLauncher/Schema.swift` in anomaly-setup-tool)
and the setup script's seed must agree on key names and defaults. Current seed
for a DXMT wrapper:

```bash
export EXE_PATH='G:\...\AnomalyDX11.exe'
export EXE_RUN_DIR='/path/to/game/bin'
export ANOMALY_GRAPHICS_BACKEND=dxmt
export WINEMSYNC=1
export WINEESYNC=1
export ROSETTA_ADVERTISE_AVX=0
export ANOMALY_RETINA_MODE=N
export MTL_HUD_ENABLED=0
export WINEDEBUG="-all"
export DEFAULT_GAME_ARGS=""
export DXMT_METALFX_SPATIAL_SWAPCHAIN=0
export DXMT_ENABLE_NVEXT=1
export DXMT_CONFIG="d3d11.displaySync=true;d3d11.sampleNaNToZero=true;"
```

Shader IR release and blit encoder merging are omitted from the seed, using
DXMT's defaults of on and off, respectively. Both are available under the
wrapper's Advanced settings.

The wrapper UI keeps a disabled setting's value as a commented line
(`#export KEY=VALUE`), so `app.env` alone carries every setting.

## Wrapper UI resources and paths

The setup tool supplies the prebuilt native UI and icon through the script's
required `--launcher-resources` directory. It contains executable
`AnomalyLauncher`, `Anomaly.icns`, `Assets.car`, and `icon-info.plist` naming `Anomaly`
for both `CFBundleIconFile` and `CFBundleIconName`. These resources are validated
before wrapper or prefix changes. `CFBundleExecutable` is `AnomalyLauncher`;
`Contents/MacOS/launcher` remains the direct Wine helper. No Finder alias or
separate Configurator is created; the old alias-suppression flag is a no-op.

`Contents/Resources/configurator-paths.json` contains `configFile`, `stateFile`,
and `winePrefix`. `stateFile` is read only for legacy disabled-setting recovery.
The executable picker writes `EXE_PATH` and `EXE_RUN_DIR` together to `app.env`;
paths use existing G: or Z: mappings. Game argument defaults are retained but
suppressed for `ModOrganizer.exe`; explicit CLI arguments still pass through.

The UI and icon are no longer required in engine archives. Legacy
`share/anomaly/Configurator.app` copies are ignored by new setup-tool builds.
Older setup-tool builds require the former layout, so distribute new setup-tool
support before publishing engines without Configurator. This is a packaging
compatibility boundary, not an engine-version gate.

## Versioning

The archive carries `engine-manifest.json` with `engineId`, `versionLabel`,
`buildNumber`, `base`, `minimumMacOS` and `minimumSetupToolVersion`; the
`.manifest.json` sidecar adds `artifact` and `artifactSHA256`. The setup tool
does not check any of these yet, so the setup-tool release must be coordinated with incompatible archive layout changes described above.
