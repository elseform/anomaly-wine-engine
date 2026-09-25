# Getting Started

How to turn an engine archive into a game app, change its settings, and find
out what went wrong. To build an archive yourself, see
[building.md](building.md).

## 1. Requirements

- An Apple Silicon Mac with macOS 15 or newer, and Rosetta 2
  (`softwareupdate --install-rosetta`).
- An existing S.T.A.L.K.E.R. G.A.M.M.A. installation.
- An engine archive (`CX26W11-GAMMA-DXMT-<N>.tar.xz`).

## 2. Create the app

Use [GAMMA Setup Tool](https://github.com/elseform/gamma-setup-tool): choose an
app name, the GAMMA folder that contains `ModOrganizer.exe`, and the engine
archive. It creates the app in `~/Applications`.

The setup tool runs its `interactive_setup.py`, which can also be used directly
from a checkout of the setup tool; every prompt has a matching flag (`--help`):

```bash
python3 sources/GAMMASetupTool/Resources/wine-engine/interactive_setup.py \
  --archive /path/to/CX26W11-GAMMA-DXMT-<N>.tar.xz
```

Setup extracts the engine into the app, creates a Wine prefix, mounts the game
root as `G:` and the host root as `Z:`, and installs the Visual C++ and DirectX
runtime files the engine declares. Those come from Microsoft's own installers,
pinned by checksum and cached for later runs; a directory of installers you
already have can be passed with `--redist-installer-dir`. The script's
`--runtime-mode verbs` installs through winetricks instead, which covers a
slightly different set (no `d3dx10_43`, no `vcruntime140_threads`).

Launch the app from Finder, or from a terminal to see log output:

```bash
open ~/Applications/<App>.app
~/Applications/<App>.app/Contents/MacOS/launcher -dbg -nointro
```

### Where things live

```text
~/Applications/<App>.app                              the app, with the engine inside
~/Applications/<App> Configurator                     alias to the app's settings editor
~/Library/Application Support/<App>/prefix            Wine prefix
~/Library/Application Support/<App>/app.env           settings
```

The prefix and settings sit outside the app, so the app can be replaced
without losing saves or settings. The app also contains `winetricks` and
`winecfg` helpers bound to its own engine and prefix:

```bash
~/Applications/<App>.app/Contents/MacOS/winetricks settings list
~/Applications/<App>.app/Contents/MacOS/winecfg
```

## 3. Changing settings

Open the `<App> Configurator` alias. It edits
`~/Library/Application Support/<App>/app.env`, which the launcher sources on
every start. Changes apply on the next launch; nothing is rebuilt.

`app.env` is plain shell and can also be edited by hand. The Configurator reads
hand edits back the next time it opens. A setting that is switched off keeps its
value as a commented line, e.g. `#export DXMT_LOG_LEVEL=debug`.

Some settings:

| Key | Effect |
|---|---|
| `DEFAULT_GAME_ARGS` | Arguments for Finder and Dock launches; arguments given on the command line win |
| `EXE_PATH`, `EXE_RUN_DIR` | The Windows path of the game executable and the macOS directory it runs in |
| `DXMT_CONFIG` | DXMT options, e.g. `d3d11.displaySync=true;d3d11.preferredMaxFrameRate=120;` |
| `DXMT_ENABLE_NVEXT` | `1` copies DXMT's `nvngx.dll` and `nvapi64.dll` into the prefix so DLSS can be detected; `0` restores what was there |
| `DXMT_METALFX_SPATIAL_SWAPCHAIN` | MetalFX spatial upscaling of the final image |
| `MTL_HUD_ENABLED` | Apple's Metal performance HUD |
| `WINEDEBUG` | Wine debug channels (`-all` silences them) |

## 4. Troubleshooting

**Which backend loaded?** Launch from a terminal. `cxcompatdb` prints one line
to stderr even with `WINEDEBUG=-all`:

```text
gamma-cxcompatdb:info: graphics backend=dxmt machine=x86_64-windows path=…/lib/dxmt
```

**The game exits immediately with no `graphics backend=` line.** Backend
validation failed and the process was terminated; there is no fallback. The
`gamma-cxcompatdb:` line before it names the missing piece. See
[renderers.md](renderers.md).

**The app will not open on an older Mac.** The engine needs macOS 15 or newer
on Apple Silicon.

**The game freezes on menu or UI clicks.** That was caused by
`maplestory-cx26-message-wait-handoff.patch`, which this engine deliberately
does not apply; see [patches/README.md](../patches/README.md).

**Start over.** Delete the app and `~/Library/Application Support/<App>/`,
then create the app again. Do not delete only `app.env`: it also holds the game
path (`EXE_PATH`, `EXE_RUN_DIR`), which only setup writes.

**Uninstall.** Delete the app, its Configurator alias, and
`~/Library/Application Support/<App>/`.
