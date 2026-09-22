# Building the Engine

How to go from this repository to a packed engine archive, and how builds are
versioned. For what the archive contains and how it behaves at runtime, see
[architecture.md](architecture.md). For what `gamma-setup-tool` expects from
it, see [setup-tool-contract.md](setup-tool-contract.md).

## Supported target

The engine runs on **Apple Silicon Macs with macOS 15 or newer**. Wine itself is
built for `x86_64` and runs under Rosetta 2. Two floors apply:

| Floor | Value | Applies to |
|---|---|---|
| Build floor | `MACOSX_DEPLOYMENT_TARGET`, default `10.15` | Wine, `ntdll.so`, `cxcompatdb.so`, the bundled dylibs |
| Product floor | `GAMMA_PRODUCT_MIN_OS`, default `15.0` | The DXMT payload (including the Metal shaders embedded in its DLLs) and the Configurator |

`scripts/pack-minos-scan.py` refuses to pack anything that needs a newer macOS
than its floor.

## Prerequisites

- An Apple Silicon Mac with Rosetta 2 (`softwareupdate --install-rosetta`).
- Xcode or the Command Line Tools: `clang`, `swiftc`, `codesign`, `otool`,
  `install_name_tool`, `python3`.
- A project-local x86_64 Homebrew in `.brew-x86/` for build tools and runtime
  libraries. `build-wine.sh --bootstrap-brew --install-deps` creates it; the
  libraries are built from source at the build floor, see
  [why-no-prebuilt-deps.md](why-no-prebuilt-deps.md).
- The CrossOver 26.3.0 source archive `crossover-sources-26.3.0.tar.gz` and the
  llvm-mingw toolchain archive (`llvm-mingw-20260616-ucrt-macos-universal`) in
  `reference/` (not tracked). `prepare-build-deps.sh` extracts them into
  `build/`; point `OGOM_ARCHIVES_DIR` elsewhere to override.
- `zstd` on `PATH` (or `GAMMA_ZSTD`) for packing.
- `gh` and `jq` for `publish-release.sh` and `fetch-dxmt.sh`.
- A built DXMT payload in `renderers/dxmt/` (tracked; see
  [The DXMT payload](#the-dxmt-payload)).

## Trees

| Path | Contents | Tracked |
|---|---|---|
| `build/cx26/sources/wine`, `build/cx26/build64` | Extracted, patched source and the out-of-tree build | no |
| `build/llvm-mingw-*` | PE cross toolchain | no |
| `install/wine-cx26-x86_64` | The live, uncompressed engine tree | no |
| `dist/artifacts/` | Packed archives with `.sha256` and `.manifest.json` | no |
| `renderers/dxmt/` | The DXMT payload staged into every build | yes |
| `config/` | Version label, release metadata, redist manifest, entitlements | yes |

Packing always works on a temporary copy, so `install/` is never stripped or
signed in place.

## Pipeline

Run the steps in this order.

1. **Build Wine** — `scripts/build-wine.sh` (first run:
   `--bootstrap-brew --install-deps`). It extracts sources
   (`prepare-build-deps.sh`), applies the patches in `patches/`
   (see [patches/README.md](../patches/README.md)), configures with
   `--enable-archs=i386,x86_64` and llvm-mingw, builds and installs into
   `install/wine-cx26-x86_64`, then runs `build-cxcompatdb.sh`,
   `bundle-wine-dylibs.sh` and `install-renderers.sh`, and writes the
   `version` file. Vulkan is off by default (`--with-vulkan` to enable).
   `--dry-run` prints the commands without running them.
2. **Optional media stack** — `scripts/build-media-stack.sh` builds GLib and
   GStreamer for `winegstreamer`; `build-wine.sh` picks it up when present.
3. **Re-stage renderers after a payload change** —
   `scripts/install-renderers.sh install/wine-cx26-x86_64`. Packing refuses to
   run when the install tree's DXMT files differ from `renderers/dxmt/`.
4. **Pack** — `scripts/pack-engine-artifact.sh` (`--dry-run` for a fast
   preflight). In order: build the Configurator (`build-configurator.sh`), copy
   the install tree to a staging `wswine.bundle/`, add the redist manifest and
   fetcher and the Configurator under `share/gamma/`, strip
   (`strip-wine-install.sh`), re-link dylibs (`bundle-wine-dylibs.sh`), sign
   every Mach-O (`sign-wine.sh`), check `cxcompatdb`, run the minOS scan, write
   `engine-manifest.json`, compress with `zstd -6`, re-extract and verify every
   signature, then write the `.sha256` and `.manifest.json` sidecars.
5. **Publish** — `scripts/publish-release.sh --dry-run`, then without
   `--dry-run`. It uploads an existing archive and its sidecars as a GitHub
   release tagged `engine-<engineId>-<N>`; it builds nothing.

Useful knobs: `GAMMA_ENGINE_COMPRESS_LEVEL` (compression level),
`GAMMA_ENGINE_FORMAT=xz` or `--xz` (xz instead of zstd),
`GAMMA_SKIP_ENGINE_STRIP=1` and `GAMMA_KEEP_DEBUG_SYMBOLS=1` (debugging a
packed tree), `SIGN_IDENTITY` (a Developer ID instead of ad-hoc signing),
`--skip-renderers` on `build-wine.sh`.

## The DXMT payload

`renderers/dxmt/` holds a built DXMT: seven x86_64 PE DLLs
(`d3d10core`, `d3d11`, `d3d12`, `dxgi`, `nvapi64`, `nvngx`, `winemetal`) and the
host bridge `x86_64-unix/winemetal.so`, plus `NOTICE`. It is built from a fork of
[DXMT](https://github.com/3Shain/dxmt) outside this repository; `NOTICE` names
the source revision. A payload is fit to ship only if it is:

- a release build installed with `meson install --strip` (a copy out of the
  Meson build directory keeps toolchain debug data and a full symbol table,
  roughly tripling its size);
- built with `MACOSX_DEPLOYMENT_TARGET=15.0`, so `winemetal.so` declares
  `minos 15.0` and the embedded Metal shaders target `macosx15.0`
  (without it both inherit the build Mac's macOS);
- x86_64 only, with no `*.dll.a` import libraries.

`scripts/fetch-dxmt.sh` replaces `renderers/dxmt/` with the newest upstream CI
build. That discards the fork's fixes and the `NOTICE`; it is not part of the
normal pipeline.

## Versioning

- **Version label** — `config/engine-version.txt`, e.g.
  `CX26.3.0-W11-Gamma087`: CrossOver version, Wine major, and a GAMMA counter
  bumped by hand when a build is meant to be kept or the patch set changes.
  `config/engine-release.json` mirrors it as `versionLabel`, and holds a
  hand-kept `engineId` slug (`cx26.3-w11-gamma087`), the base versions
  (`crossover`, `wine`), `minimumMacOS`, and the ordered patch list.
- **Archive name** — DXMT-only builds (the normal case) are named
  `CX<crossover-major>W<wine-major>-GAMMA-DXMT-<N>.tar.zst`; a build with a
  staged D3DMetal payload is named `CX26W11-Gamma087-<N>.tar.zst`. Naming lives
  in `scripts/engine-common.sh`.
- **Build number** — `<N>` is one more than the highest existing archive for
  that name in `dist/artifacts/`. It is recorded as `buildNumber` in both
  manifests. It is not stored anywhere else, so deleting old archives restarts
  the count.
- **Base bumps** — a new CrossOver source archive needs
  `prepare-build-deps.sh` updated, `base` in `engine-release.json` updated to
  what the tree reports (`build/cx26/sources/wine/VERSION`), and a review of the
  patch set, which is pinned to specific source trees.

## Maintainer tools

- `scripts/write-redist-manifest.py` rebuilds `config/redist-manifest.json` from
  the pinned Microsoft installers; `--check` verifies it without writing.
- `scripts/run-winetricks.sh` runs winetricks against this repository's engine
  for local testing.

## Known limitations

- The Configurator is built for Apple Silicon only.
- `engineId` in `engine-release.json` is typed by hand and must be kept in step
  with the version label.
- A complete from-scratch `build-wine.sh` run has not been re-timed recently;
  incremental builds over an existing `build/` tree are the tested path.
