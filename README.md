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
| [Manual Setup](docs/manual-setup.md) | Prefix/launch steps by hand, without `interactive_setup.py` (lives in `gamma-setup-tool`) |

### Key Features

- **Base Runtime**: CrossOver 26.3.0 built on **Wine 11.0** (`x86_64` under Rosetta 2 on Apple Silicon).
- **Switchable Graphics Backends**: D3DMetal and DXMT ship side by side using CrossOver's directory convention; WineD3D remains an internal fallback. See [docs/renderers.md](docs/renderers.md).
  - **DXMT**: Default (via `interactive_setup.py`). D3D11/10 via Metal, and the only Metal backend for 32-bit processes.
  - **Apple D3DMetal (GPTK)**: Selectable alternative, 64-bit Direct3D 11/12 via Metal. Optional and user-supplied — GPTK is Apple's own licensed toolkit, not bundled in this repo. See [docs/renderers.md](docs/renderers.md).
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
| **Interactive Setup Script** | `gamma-setup-tool/sources/GAMMASetupTool/Resources/wine-engine/interactive_setup.py` + `Anomaly.icns` | Lives in `gamma-setup-tool`, not here — `gamma-setup-tool`'s own `build.sh` bundles it into `GAMMA Setup Tool.app`. The engine archive itself is *not* bundled there either; `gamma-setup-tool` downloads it from a published release (`scripts/publish-release.sh`) at setup time |

---

## Dedicated Scripts

### 1. Interactive Setup (`interactive_setup.py`, lives in `gamma-setup-tool`)

Builds a fully self-contained `.app` from an engine `.tar.zst` (or explicit legacy `.tar.xz`): extracts the engine, bootstraps a
prefix, installs dependencies through winetricks by default (or bundled redist as an explicit
fallback), and writes the bundle metadata, launcher, prefix-aware `winetricks`, and `winecfg`
helpers. Standalone, stdlib-only Python — calls no other repo script and needs nothing beyond
`python3` itself plus the same external tools (`wine`, `tar`/`zstd`, `winetricks`, `codesign`,
`osascript`, `lsregister`) it always did.
The generated `app.env` also exposes `EXE_PATH` and `EXE_RUN_DIR`, so the target can be changed
later without rebuilding the app.

The script itself now lives at
`gamma-setup-tool/sources/GAMMASetupTool/Resources/wine-engine/interactive_setup.py` (moved out
of this repo to end the two-copy vendoring drift — `gamma-setup-tool/build.sh` was the only thing
that ever needed a copy of it). Run it standalone from there:

```bash
python3 ../gamma-setup-tool/sources/GAMMASetupTool/Resources/wine-engine/interactive_setup.py \
  --archive dist/artifacts/<artifact>.tar.zst
```

Every prompt above also has a matching flag (`--archive`, `--app-name`, `--app-parent`,
`--gamma-root`, `--exe-rel-path`, `--backend`, `--runtime-mode`, `--yes`) for non-interactive/
scripted use, plus `--json` to emit newline-delimited JSON progress events instead of plain text.
See `--help` for the full list.

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

### 4. Publish Release (`scripts/publish-release.sh`)

Uploads an already-built `dist/artifacts/*.tar.zst` (or `.tar.xz`), its manifest, and its
checksum to a GitHub Release — it does not build anything itself, only publishes what
`pack-engine-artifact.sh` already produced, so `gamma-setup-tool` (or anyone else) has a
stable URL to download instead of requiring a local build. Requires the `gh` CLI, already
authenticated with push access to this repo. Always dry-run first — creating a public
release is a real, hard-to-reverse publish action.

```bash
scripts/publish-release.sh --dry-run
scripts/publish-release.sh
```

## Manual Prefix Setup

`scripts/interactive_setup.py` automates prefix creation, drive mappings,
registry values, and dependency installation. For doing any of that by hand
(debugging, or understanding what the script does), see
[docs/manual-setup.md](docs/manual-setup.md).

`renderers/dxmt/` currently carries a locally-built, non-upstream payload
(`fix2-3-winemetal-cbuffer-9434028` — a GPU page-fault fix built from a
custom `dxmt` fork), not the upstream CI artifact `scripts/fetch-dxmt.sh`
fetches. Running that script overwrites it with vanilla `3Shain/dxmt`.
