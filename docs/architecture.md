# Architecture

What the engine archive is, how it selects a graphics backend at runtime, and
the pieces that ship next to Wine. For producing an archive, see
[building.md](building.md); for how `gamma-setup-tool` consumes it, see
[setup-tool-contract.md](setup-tool-contract.md).

## What this repository produces

One artifact: a relocatable Wine 11.16 / CrossOver 26.3.0 engine, built for
`x86_64` and run under Rosetta 2 on Apple Silicon Macs with macOS 15 or newer.

```text
dist/artifacts/CX26-W11-GAMMA-<N>.tar.xz
                                  .tar.xz.sha256
                                  .tar.xz.manifest.json
```

The engine is not an app on its own. `gamma-setup-tool` extracts it into a
wrapper app, creates a Wine prefix, and writes the launcher; see
[getting-started.md](getting-started.md).

## Archive layout

```text
wswine.bundle/
  bin/                          wine, wineserver, and the other Wine tools
  lib/wine/x86_64-windows/      Wine's PE builtins, plus a copy of winemetal.dll
  lib/wine/i386-windows/        Wine's 32-bit PE builtins
  lib/wine/x86_64-unix/         Wine's unix side, bundled dylibs, cxcompatdb.so
  lib/dxmt/x86_64-windows/      DXMT: d3d10core, d3d11, d3d12, dxgi, nvapi64, nvngx, winemetal
  lib/dxmt/x86_64-unix/         DXMT's host bridge, winemetal.so
  share/gamma/redist-manifest.json
  share/gamma/redist-fetch/     gamma_redist.py, which installs the Microsoft runtime files
  engine-manifest.json          identity, build number, base versions, patch list
  version                       the version label
```

Every Mach-O is signed (ad-hoc unless `SIGN_IDENTITY` is set). Wine's PE
modules are stripped of debug data during packing.

## Backend selection at runtime

`cxcompatdb.so` (`runtime/cxcompatdb/cxcompatdb.c`) is loaded by CrossOver's
`ntdll` in every Wine process. It reads `GAMMA_GRAPHICS_BACKEND`
(unset or `dxmt`; DXMT is the only backend), finds the engine root from the loaded
`ntdll.so`, and validates the backend for the process's architecture. For
`dxmt` it requires `d3d11`, `dxgi` and `winemetal` in
`lib/dxmt/<arch>-windows/` and `lib/dxmt/x86_64-unix/winemetal.so`. It then sets
a builtin load order for each graphics module present there and puts
`lib/dxmt` first on Wine's DLL search path.

There is no fallback. If validation fails, the process exits with a
`gamma-cxcompatdb:` line on stderr giving the reason. DXMT is x86_64-only, so a
32-bit process under `dxmt` is terminated too.

Two consequences of this layout:

- `lib/wine/x86_64-windows/winemetal.dll` is a copy of DXMT's `winemetal.dll`
  (debug data stripped) so that `wineboot` finds it and creates the prefix
  entry. The copy in `lib/dxmt` is the one that loads.
- The prefix's `system32` holds Wine's own `d3d11.dll`, `dxgi.dll` and
  `winemetal.dll` from `wineboot`. They are marked as builtins, so Wine loads
  the modules from its DLL search path — `lib/dxmt` first — instead.

A launch from a terminal prints the selected backend:

```text
gamma-cxcompatdb:info: graphics backend=dxmt machine=x86_64-windows path=…/lib/dxmt
```

## Wrapper UI

`gamma-setup-tool` owns the native settings and launcher application, its
Gamma icon, and the schema and persistence of `app.env`. The setup tool builds
these resources independently and installs them as the wrapper's main UI.
This repository owns the runtime environment-variable interface consumed by
Wine and DXMT, not its editor.

Engine packing neither builds nor includes Configurator. The setup tool accepts
older engine archives containing it but does not use it. Older setup-tool builds
require that legacy archive layout; updated setup-tool support must ship before
an engine archive without Configurator is published. See
[Setup Tool Contract](setup-tool-contract.md).

## Microsoft runtime files

The engine ships no Microsoft DLLs. `config/redist-manifest.json` (packed as
`share/gamma/redist-manifest.json`) lists the Visual C++ 2022 and DirectX files
the game needs, each with the Microsoft installer it comes from, pinned by URL
and SHA-256. At wrapper creation `gamma_redist.py` downloads the installers
(or uses local copies), extracts the files with the system `bsdtar` and plain
Python (no `cabextract` or `7z`), checks every file's SHA-256, and installs them
into the prefix. `d3dcompiler_47.dll` has no public Microsoft installer; it comes
from the `mozilla/fxc2` build that winetricks also uses.

## Patches

`patches/` holds the source patches `build-wine.sh` applies to CrossOver
26.3.0; the list is recorded in `config/engine-release.json` and in every
manifest. Details and the patches deliberately left out are in
[patches/README.md](../patches/README.md). Filenames with a `cyder-` prefix are
kept for provenance.

## Conventions

- Every script derives the repository root from its own location; `OGOM` is a
  legacy name for that root inside `env-x86_64.sh`.
- Environment variables use the `GAMMA_` prefix.
- `CrossOver.app` is only used, when present, as an optional MoltenVK source for
  a Vulkan-enabled build; the engine never references it at runtime.
