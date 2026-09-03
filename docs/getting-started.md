# Getting Started

How to go from this repo to a working `.app` you can double-click, and how to
change its settings afterwards.

If you only want to *run* the game, you need §1 and §2. Everything after that
is tuning and troubleshooting.

---

## 1. Requirements

- Apple Silicon Mac with Rosetta 2 installed (`softwareupdate --install-rosetta`)
- macOS 10.15 or newer
- A copy of the game on disk, e.g. `~/gamma`
- An engine archive: either a prebuilt `dist/artifacts/*.tar.xz`, or one you
  build yourself (see [§5](#5-building-the-engine-yourself))

Nothing else is required to *use* an engine archive. Building one needs more —
see [architecture.md](architecture.md).

## 2. Create the app

```bash
bash scripts/interactive-setup.sh
```

It asks for the core choices below and provides defaults for all of them:

| Prompt | Default |
|---|---|
| Path to engine tar.xz | newest archive in `dist/artifacts/` |
| Name for the .app bundle | `GAMMA` |
| Directory to place the .app in | `~/Applications` |
| Path to game root (G: drive) | `~/gamma` |
| Path to .exe, relative to game root | `3dss5/bin/AnomalyDX11AVX.exe` |
| Graphics backend | `d3dmetal` |
| cxcompatdb policy | `real` |

Then it extracts the engine, bootstraps a Wine prefix, installs the winetricks
verbs the game needs (`d3dx9_43`, `d3dx11_43`, `d3dcompiler_43/47`,
`vcrun2022`, `win10`, CoreAudio), writes the launcher, and ad-hoc signs the
bundle. Expect a few minutes, mostly winetricks.

The `debug_dummy` cxcompatdb choice keeps explicit `GAMMA_GRAPHICS_BACKEND`
activation and `winemenubuilder.exe` suppression. It removes automatic backend
selection, legacy selector aliases, fixed DirectX helper overrides, and every
external CompatDB rule action; external databases are parsed only for
diagnostics. Artifacts built before this variant was added cannot use that
choice and setup stops with a clear error.

Launch it from Finder, or from a terminal to see log output:

```bash
open ~/Applications/GAMMA.app
# or
~/Applications/GAMMA.app/Contents/MacOS/launcher -dbg -nointro
```

### Where things live

```
~/Applications/GAMMA.app/Contents/MacOS/launcher       thin launcher
~/Applications/GAMMA.app/Contents/MacOS/winetricks    prefix-aware winetricks launcher
~/Applications/GAMMA.app/Contents/Resources/engine/    the engine (read-only)

~/Library/Application Support/GAMMA/prefix             Wine prefix
~/Library/Application Support/GAMMA/app.env            your settings
```

The prefix and settings deliberately sit **outside** the bundle. The app stays
signed and replaceable, and your saves/config survive rebuilding it.

Run additional winetricks verbs through the generated helper so they use this
app's bundled Wine engine and prefix:

```bash
~/Applications/GAMMA.app/Contents/MacOS/winetricks settings list
~/Applications/GAMMA.app/Contents/MacOS/winetricks -q d3dcompiler_47
```

The helper finds Homebrew winetricks in its standard Apple Silicon or Intel
location, then falls back to `PATH`. Set `WINETRICKS_BIN` to an executable path
when using another installation.

## 3. Changing settings

Everything is in one file:

```
~/Library/Application Support/<AppName>/app.env
```

Plain bash, sourced by the launcher on every start, *before* its defaults — so
whatever you set there wins. Edit, save, relaunch. No rebuild, and editing it
cannot break the bundle signature.

The file is generated with every renderer option present but commented out,
each with a description and its value range, so you rarely need to look
anything up. Switching renderer is one line:

```bash
export GAMMA_GRAPHICS_BACKEND=dxmt
```

| Backend | What it is | Notes |
|---|---|---|
| `d3dmetal` | Apple D3DMetal (GPTK 4.0b1), D3D11/12 → Metal | Default. 64-bit only. |
| `dxmt` | DXMT, D3D11/10 → Metal | The only Metal backend for 32-bit processes. |
| `dxvk` | DXVK, D3D11/10/9 → Vulkan → MoltenVK | Needs a Vulkan engine build; otherwise falls back. |
| `wined3d` | Wine's OpenGL renderer | Always works, slowest. |
| `default` | Try d3dmetal, then dxmt, then wined3d | |

A couple of examples of what the commented blocks offer:

```bash
# D3DMetal
export D3DM_ENABLE_METALFX=1
export D3DM_MAX_FPS=120

# DXMT
export DXMT_METALFX_SPATIAL_SWAPCHAIN=1
export DXMT_CONFIG="d3d11.metalSpatialUpscaleFactor=1.5;d3d11.preferredMaxFrameRate=120"
```

`DEFAULT_GAME_ARGS` sets the arguments used for Finder/Dock launches; anything
passed on the command line overrides it.

The target executable is configurable there too. `EXE_PATH` is the Windows
path passed to Wine. When switching to an executable in another directory,
change `EXE_RUN_DIR` to the corresponding macOS directory so the game can find
its adjacent DLLs and configuration files:

```bash
export EXE_PATH='G:\3dss5\bin\AnomalyDX10AVX.exe'
export EXE_RUN_DIR="$HOME/gamma/3dss5/bin"
```

## 4. Troubleshooting

**Which backend actually loaded?** Launch from a terminal. `cxcompatdb` prints
one line to stderr, and `WINEDEBUG=-all` does not silence it:

```
gamma-cxcompatdb:info: graphics backend=dxmt machine=x86_64-windows path=…/lib/dxmt
```

**It says `backend=wined3d` but I asked for something else.** The line above it
gives the reason — a missing DLL for your architecture, a missing
`winemetal.dll` for DXMT, or a missing `libMoltenVK.dylib` for DXVK. Falling
back is deliberate: a bad backend choice degrades instead of failing to start.

**32-bit process fell back to wined3d.** D3DMetal ships no 32-bit payload. Use
`dxmt`, or `default` to let the engine pick per process.

**DXMT crashes during startup.** Known and unresolved — the game dies just
after material loading with a `FATAL ERROR / invalid_parameter_handler` dialog.
Use `d3dmetal` for now. Details, what has been ruled out, and how to pick the
investigation back up are in
[renderers.md](renderers.md#known-issue-dxmt-crashes-during-startup).

**`dxvk` never activates.** Expected right now — see
[renderers.md](renderers.md#dxvk-staged-but-not-active). The engine has to be
rebuilt with Vulkan first.

**The game freezes on menu or UI clicks.** This was caused by
`maplestory-cx26-message-wait-handoff.patch`, which is deliberately not applied
in this repo. If you see it again, check nothing re-added it — see
[patches/README.md](../patches/README.md).

**Start over.** Delete `~/Library/Application Support/<AppName>/` and re-run
the setup script. Deleting only `app.env` regenerates the settings file with
current defaults while keeping the prefix.

**Uninstall.** Delete the `.app` and `~/Library/Application Support/<AppName>/`.
Nothing is installed anywhere else.

## 5. Building the engine yourself

Only needed if you want to change patches, renderers, or Wine itself.

```bash
# first time: project-local x86_64 Homebrew + build dependencies
bash scripts/build-wine.sh --cx 26 --without-vulkan --bootstrap-brew --install-deps

# subsequent builds
bash scripts/build-wine.sh --cx 26 --without-vulkan

# package it
bash scripts/pack-engine-artifact.sh --force
```

The first run compiles a lot from source and takes a long time; see
[why-no-prebuilt-deps.md](why-no-prebuilt-deps.md) for why bottles cannot be
used. `pack-engine-artifact.sh` writes
`dist/artifacts/<artifactBasename>.tar.xz` plus a `.sha256` and a
`.manifest.json`, then `interactive-setup.sh` picks it up.

For what each script does and how they fit together, read
[architecture.md](architecture.md).
