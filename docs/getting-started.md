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
- An engine archive: either a prebuilt `dist/artifacts/*.tar.zst`, or one you
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
| Path to engine archive | newest `.tar.zst` archive in `dist/artifacts/` |
| Name for the .app bundle | `GAMMA` |
| Directory to place the .app in | `~/Applications` |
| Path to game root (G: drive) | `~/gamma` |
| Path to .exe, relative to game root | `sept/bin/AnomalyDX11.exe` |
| Graphics backend | `dxmt` |
| Runtime dependencies | `redist` |

Then it extracts the engine, bootstraps a Wine prefix, installs the required
dependencies, writes the launcher, and ad-hoc signs the bundle. `redist`
copies the bundled DLL payload (`d3dx9_43`, `d3dx10_43`, `d3dx11_43`,
`d3dcompiler_43/47`, `concrt140`/`msvcp140`/`vc*140` family) and registers its
fallback overrides — no network access needed. Select `verbs` instead when you
need what winetricks covers that `redist` doesn't (see the comparison below);
it installs its components via winetricks, which create their own DLL
overrides. If no usable winetricks exists, setup downloads the current script
into the app's external cache.

### `verbs` and `redist` are not equivalent

They do not stage the same DLL set — pick one because you need what it
covers, not interchangeably with the other.

| | `verbs` | `redist` (default) |
|---|---|---|
| Source | `scripts/interactive-setup.sh`'s winetricks call: `d3dx9_43 d3dx11_43 d3dcompiler_43 d3dcompiler_47 vcrun2022 win10 sound=coreaudio` | Every file under `runtime/redist/x86_64-windows/`: `concrt140`, `d3dcompiler_43/47`, `d3dx9_43`, `d3dx10_43`, `d3dx11_43`, `msvcp140` + 4 companion DLLs, `vcamp140`, `vccorlib140`, `vcomp140`, `vcruntime140`, `vcruntime140_1`, `vcruntime140_threads` |
| `d3dx10_43` | **Not installed.** No `d3dx10_43` verb is requested — winetricks has one (`winetricks list-all` confirms it), it is just never called here. D3DX10 stays on Wine's own (limited) builtin. | Installed as a native override. |
| `vcruntime140_threads.dll` | Not provided; `vcrun2022`'s own file list omits it. | Installed as a native override. |
| DLL override policy | Set per-verb by winetricks itself, and not uniform: e.g. `d3dx9_43` registers `native` only, while `vcrun2022`'s files (including `vcruntime140`) register `native,builtin` | `native,builtin` for every file above, uniformly — falls back to Wine's builtin if the native copy is ever missing |
| Provenance | Genuine Microsoft installers, downloaded (and cached) by winetricks | Whatever is checked into `runtime/redist/`; update it manually to move to a newer vcredist |

(`verbs` row checked against a live prefix's
`HKEY_CURRENT_USER\Software\Wine\DllOverrides`; `redist` row read from this
script's own redist-branch loop, which is unconditional. Override value
names are prefixed with `*`, e.g. `*vcruntime140`.)

Practically: content that specifically needs D3DX10 (or, less likely,
`vcruntime140_threads.dll`) behaves differently depending on which mode
created the prefix. Neither mode is recorded anywhere after setup finishes.
Because override policy isn't a clean two-way split (`vcruntime140` reads
`native,builtin` under *both* modes), check `d3dx10_43` instead — it only
ever exists under `redist`:

```bash
WINEPREFIX="$HOME/Library/Application Support/<AppName>/prefix" \
  arch -x86_64 ~/Applications/<AppName>.app/Contents/Resources/engine/bin/wine \
  reg query "HKEY_CURRENT_USER\Software\Wine\DllOverrides" /v "*d3dx10_43"
```

Found → `redist`. `Unable to find the specified registry value` → `verbs`.

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
~/Applications/GAMMA.app/Contents/MacOS/winecfg       prefix-aware WineCfg launcher
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
~/Applications/GAMMA.app/Contents/MacOS/winecfg
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
| `dxmt` | DXMT, D3D11/10 → Metal | Default (via `interactive-setup.sh`). The only Metal backend for 32-bit processes. |
| `d3dmetal` | Apple D3DMetal (GPTK 4.0b2), D3D11/12 → Metal | 64-bit only. |

WineD3D is not selectable, and there is no fallback to it: if the chosen
backend fails validation for a process, `cxcompatdb` terminates that process
instead of silently degrading. The engine never tries the other Metal backend.

**`d3dmetal` gets one extra, permanent registry override that `dxmt` does
not.** GPTK's own `d3d10.dll`/`d3d10.so` are excluded from the D3DMetal
payload — they share `libd3dshared` state with D3D11 and caused a confirmed
savegame hang. `interactive-setup.sh` writes a one-time, per-executable
override instead (`HKEY_CURRENT_USER\Software\Wine\AppDefaults\<exe>\DllOverrides`,
`d3d10=builtin`), pinning that one process to Wine's own D3D10 rather than
leaving resolution to `cxcompatdb`. This is **not** something `cxcompatdb`
does — it has no override policy of its own (see [architecture.md § The
backend switcher](architecture.md#the-backend-switcher)); this override is
written once, at setup time, by the setup script itself, and only when
`GAMMA_GRAPHICS_BACKEND` was `d3dmetal` at the time. Switching to `dxmt` in
`app.env` afterward does not remove it (harmless — DXMT ships its own
`d3d10core.dll` and never goes through this path), and setting up a fresh
app with `dxmt` selected never writes it in the first place. Also documented
in [renderers.md § Selection and fallback](renderers.md#selection-and-fallback).

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

What `cxcompatdb` actually does (and does not do — it has no DLL-override or
redist/verbs policy of its own) is in
[architecture.md § The backend switcher](architecture.md#the-backend-switcher).

**The process exited immediately with no `graphics backend=` line.** Backend
validation failed and `cxcompatdb` terminated the process — there is no
fallback to WineD3D. The preceding stderr line gives the reason: a missing or
invalid DLL for the current architecture, a missing `winemetal` bridge for
DXMT, or missing D3DMetal host support.

**32-bit process terminated under `d3dmetal`.** D3DMetal ships no 32-bit
payload, and there is no fallback — the process is killed. Set
`GAMMA_GRAPHICS_BACKEND=dxmt` when 32-bit Metal support is required.

**DXMT crashes during startup.** Known and unresolved — the game dies just
after material loading with a `FATAL ERROR / invalid_parameter_handler` dialog.
Use `d3dmetal` for now. Details, what has been ruled out, and how to pick the
investigation back up are in
[renderers.md](renderers.md#known-issue-dxmt-crashes-during-startup).

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
`dist/artifacts/<artifactBasename>.tar.zst` plus a `.sha256` and a
`.manifest.json`, then `interactive-setup.sh` picks it up.

For what each script does and how they fit together, read
[architecture.md](architecture.md).
