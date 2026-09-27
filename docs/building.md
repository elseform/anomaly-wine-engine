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
| Product floor | `GAMMA_PRODUCT_MIN_OS`, default `15.0` | The DXMT payload (including the Metal shaders embedded in its DLLs) |

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
- `xz` on `PATH` for packing (Homebrew `xz`); `zstd` only for the optional `--zstd` format.
- `gh` for `publish-release.sh`; `curl` and network access to GitHub for
  packing, which downloads DXMT (see [The DXMT payload](#the-dxmt-payload)).

## Trees

| Path | Contents | Tracked |
|---|---|---|
| `build/cx26/sources/wine`, `build/cx26/build64` | Extracted, patched source and the out-of-tree build | no |
| `build/llvm-mingw-*` | PE cross toolchain | no |
| `install/wine-cx26-x86_64` | The live, uncompressed engine tree | no |
| `dist/artifacts/` | Packed archives with `.sha256` and `.manifest.json` | no |
| `build/cache/dxmt/<tag>/` | Downloaded, verified DXMT releases | no |
| `renderers/dxmt/NOTICE` | DXMT's license notice, shipped as `lib/dxmt/NOTICE` | yes |
| `config/` | Version label, last build number, release metadata, redist manifest, entitlements | yes |

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
   `bundle-wine-dylibs.sh` and `install-renderers.sh` (which keeps backend
   files out of the install tree), and writes the
   `version` file. Vulkan is off by default (`--with-vulkan` to enable).
   `--dry-run` prints the commands without running them.
2. **Optional media stack** — `scripts/build-media-stack.sh` builds GLib and
   GStreamer for `winegstreamer`; `build-wine.sh` picks it up when present.
3. **Pack** — `scripts/pack-engine-artifact.sh` (`--dry-run` for a fast
   preflight that resolves the DXMT release without downloading it). In
   order: fetch and verify DXMT (`fetch-dxmt-release.sh`), copy the install
   tree to a staging `wswine.bundle/`, add DXMT under `lib/dxmt/` (plus the
   `winemetal.dll` copy in `lib/wine/x86_64-windows/` and `NOTICE`), add the
   redist manifest and fetcher under `share/gamma/`, strip
   (`strip-wine-install.sh`), re-link dylibs (`bundle-wine-dylibs.sh`), sign
   every Mach-O (`sign-wine.sh`), check `cxcompatdb`, run the minOS scan, write
   `engine-manifest.json`, compress with `xz -6`, re-extract and verify every
   signature, then write the `.sha256` and `.manifest.json` sidecars.
4. **Publish** — `scripts/publish-release.sh --dry-run`, then without
   `--dry-run`. It uploads an existing archive and its sidecars as a GitHub
   release tagged `engine-<engineId>-<N>`; it builds nothing, and refuses an
   archive whose DXMT did not come from an `elseform/dxmt` release.

Useful knobs: `GAMMA_ENGINE_COMPRESS_LEVEL` (compression level),
`GAMMA_ENGINE_FORMAT=zstd` or `--zstd` (zstd instead of xz; gamma-setup-tool does not accept it),
`GAMMA_SKIP_ENGINE_STRIP=1` and `GAMMA_KEEP_DEBUG_SYMBOLS=1` (debugging a
packed tree), `SIGN_IDENTITY` (a Developer ID instead of ad-hoc signing),
`--skip-renderers` on `build-wine.sh`.

## The DXMT payload

DXMT is not stored in this repository. Packing downloads it from a release of
[`elseform/dxmt`](https://github.com/elseform/dxmt), the maintained fork of
[DXMT](https://github.com/3Shain/dxmt): by default the newest release tagged
`gamma-YYYY.MM.DD`, or the one named by `--dxmt-tag TAG`.
`scripts/fetch-dxmt-release.sh` downloads the release's
`dxmt-macos-x86_64-<tag>.tar.gz`, `.sha256` and `.manifest.json` into
`build/cache/dxmt/<tag>/` and verifies them on every pack: the tarball against
its `.sha256`, each file against the manifest, and the file set against the
eight expected files (seven x86_64 PE DLLs — `d3d10core`, `d3d11`, `d3d12`,
`dxgi`, `nvapi64`, `nvngx`, `winemetal` — and the host bridge
`x86_64-unix/winemetal.so`). Any mismatch stops the pack; delete the cache
directory to download again. The tag, commit and tarball checksum go into
`engine-manifest.json` as `dxmt`.

The fork's releases are built to the requirements this engine needs: a
release build installed with `meson install --strip`, `MACOSX_DEPLOYMENT_TARGET=15.0`
(checked again by the minOS scan), x86_64 only.

`--dxmt DIR` packs a local, unreleased payload with the same `x86_64-windows/`
and `x86_64-unix/` layout, for testing a DXMT change before it is released.
Such an archive's manifest records `dxmt.source: "local"`, and
`publish-release.sh` refuses it.

## Versioning

- **Version label** — `config/engine-version.txt`, e.g. `CX26-W11-GAMMA`:
  CrossOver major and Wine major. It changes only with a new CrossOver or
  Wine major; builds are told apart by the build number below.
  `config/engine-release.json` mirrors it as `versionLabel`, and holds a
  hand-kept `engineId` slug (`cx26-w11-gamma`, also the release tag prefix
  `engine-cx26-w11-gamma-<N>`), the exact base versions (`crossover`,
  `wine`), `minimumMacOS`, and the ordered patch list.
- **Archive name** — the version label plus the build number,
  `CX26-W11-GAMMA-<N>.tar.xz` (builds up to `-18` were named
  `CX26W11-GAMMA-DXMT-<N>.tar.xz`). Naming lives in `scripts/engine-common.sh`.
- **Build number** — `<N>` is `config/build-number` (the last packed build)
  plus one, or whatever `--build-number N` sets. A successful pack writes `<N>`
  back to `config/build-number`; commit it. It is recorded as `buildNumber` in
  both manifests and in the release tag. `gamma-setup-tool` orders releases by
  it, so it must keep growing. Old archives in `dist/artifacts/` can be deleted
  freely.
- **Base bumps** — a new CrossOver source archive needs
  `prepare-build-deps.sh` updated, `base` in `engine-release.json` updated to
  what the tree reports (`build/cx26/sources/wine/VERSION`), and a review of the
  patch set, which is pinned to specific source trees.

## Maintainer tools

- `scripts/write-redist-manifest.py` rebuilds `config/redist-manifest.json` from
  the pinned Microsoft installers; `--check` verifies it without writing.

## Known limitations

- The native wrapper UI is built and distributed by `gamma-setup-tool`, independently of engine packing.
- `engineId` in `engine-release.json` is typed by hand and must be kept in step
  with the version label.
- A complete from-scratch `build-wine.sh` run has not been re-timed recently;
  incremental builds over an existing `build/` tree are the tested path.
