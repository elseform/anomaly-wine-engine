# How This Repo Works

What each piece is, how a build flows from source archive to `.app`, and the
conventions worth knowing before changing anything.

For using the result, see [getting-started.md](getting-started.md). For the
graphics backends specifically, see [renderers.md](renderers.md).

---

## What this repo produces

One artifact: a relocatable Wine 11.0 / CrossOver 26.3.0 engine for `x86_64`
under Rosetta 2, packed as a tarball rooted at `wswine.bundle/`, with D3DMetal
GPTK 4.0b2 and DXMT baked in.

```
dist/artifacts/<artifactBasename>.tar.zst
                                   .sha256
                                   .manifest.json
```

`<artifactBasename>` is derived from the version label (e.g.
`CX26W11-Gamma086` from `CX26.3.0-W11-Gamma086`) — see
[Versioning Policy](versioning-policy.md).

The `wswine.bundle/` root is not cosmetic — it is what `gamma-setup-tool`'s
`installEngine()` expects to find when it extracts an engine.

## Directory map

| Path | Contents |
|---|---|
| `scripts/` | The entire build and packaging pipeline (15 files) |
| `patches/` | Wine/CrossOver source patches, applied in a fixed order |
| `runtime/cxcompatdb/` | `cxcompatdb.c` — the backend switcher, built into the engine |
| `config/` | Release metadata, version label, entitlements |
| `sources/` | Upstream inputs: CrossOver tarball, llvm-mingw, GPTK4, DXMT |
| `build/` | Extracted and patched trees; produced, never edited by hand |
| `install/` | The live uncompressed engine tree |
| `dist/artifacts/` | Packaged releases |
| `.brew-x86/` | Project-local x86_64 Homebrew |
| `docs/` | These documents |

`build/`, `install/`, `dist/`, `sources/` and `.brew-x86/` are gitignored.

## The pipeline

### Stage 0 — environment

`scripts/env-x86_64.sh` is sourced by every build script and defines the whole
path universe: `WINE_SRC`, `WINE_INSTALL`, `HOMEBREW_PREFIX`,
`GRAPHICS_INSTALL`, `MEDIA_INSTALL`, `ENTITLEMENTS_PLIST`, the minOS floor, and
the CrossOver.app auto-detection. It also loads an optional gitignored `.env`.

`scripts/engine-common.sh` holds the version-label and artifact-naming helpers
used by the packaging scripts.

Neither is executable on its own.

### Stage 1 — sources

`prepare-build-deps.sh --cx 26` extracts `sources/crossover-sources-26.3.0.tar.gz`
and the llvm-mingw toolchain into `build/`. It is called automatically by
`build-wine.sh`, so you rarely run it directly.

`fetch-dxmt.sh` pulls the newest successful DXMT CI build from `3Shain/dxmt`
via `gh run download` into `sources/dxmt`. D3DMetal comes from
`sources/gptk40b2/d3dmetal`.

### Stage 2 — build Wine

`build-wine.sh` is the main entry point and does, in order:

1. Parse flags, source the environment, extract sources
2. Optionally bootstrap `.brew-x86` and install build dependencies
3. Sanitize `PATH` so nothing picks up arm64 `/opt/homebrew` tools
4. Apply `patches/` in a fixed sequence (idempotent — safe to re-run)
5. `configure` out-of-tree in `build64/` with the minOS baked into `CFLAGS`
6. `make` and `make install` into `install/wine-cx26-x86_64/`
7. Chain `build-cxcompatdb.sh`, `bundle-wine-dylibs.sh`, `install-renderers.sh`
8. Write the engine version file

Everything runs under `arch -x86_64`. `--dry-run` prints the commands without
executing them, which is the cheapest way to check a change.

`build-media-stack.sh` builds the GLib/GStreamer stack for `winegstreamer`
separately; `build-wine.sh` wires it in automatically if it finds one.

### Stage 3 — assemble the tree

- `build-cxcompatdb.sh` compiles `runtime/cxcompatdb/cxcompatdb.c` into the
  production `lib/wine/x86_64-unix/cxcompatdb.so`
- `bundle-wine-dylibs.sh` copies Homebrew runtime dylibs into the tree and
  rewrites their install names to `@loader_path`, making the tree relocatable
- `install-renderers.sh` stages GPTK 4.0b2 under `lib64/apple_gptk`, DXMT under
  `lib/dxmt`, and restores any Wine builtin a previous run shadowed

### Stage 4 — package

`pack-engine-artifact.sh` orchestrates the release:

```
rsync install tree → staging/wswine.bundle
  → strip-wine-install.sh     drop headers, man pages, dev binaries, DWARF
  → bundle-wine-dylibs.sh     re-relink in the staged copy
  → sign-wine.sh              codesign every Mach-O
  → pack-minos-scan.py        fail if any binary's minos exceeds the floor
  → tar + xz/zstd
  → write-engine-manifest.sh  manifest, twice: pre-tar and post-tar with sha256
```

The minOS gate is the strictest check: the floor is 10.15, and only
`lib/dxmt/**` and `lib64/apple_gptk/**` are exempt (upstream DXMT and Apple's
D3DMetal declare higher minimums). Everything else — `wine`, `wineserver`, all
`.so` files, all bundled dylibs — must not regress the floor.

### Stage 5 — the app

`interactive-setup.sh` consumes the tarball and produces the `.app`. It is
deliberately standalone: it calls no other script here, so it works from just
an archive on a machine that has never seen this repo.

## The backend switcher

`cxcompatdb.so` is a small unix-side plugin that CrossOver's `ntdll` loads at
process start. It accepts only `GAMMA_GRAPHICS_BACKEND=d3dmetal|dxmt`, validates
the selected backend for the running architecture, and calls
`prepend_dll_path()` once. There is no WineD3D fallback: if validation fails
for any reason — invalid env value, missing/corrupt module for the running
architecture, missing native support library — it terminates the process
instead. It has no external database, compatibility aliases, automatic
backend chain, or DirectX/VC++ helper policy.

Because it runs per process, this also applies to 32-bit children of a
64-bit game: D3DMetal has no 32-bit payload, so any 32-bit process spawned
under `GAMMA_GRAPHICS_BACKEND=d3dmetal` is terminated by this constructor.
Use `dxmt` when a 32-bit process needs a Metal backend.

Full detail, including the tree layout it depends on and why `winemetal` is
special, is in [renderers.md](renderers.md).

## Patches

`patches/` holds 16 files; 15 are applied by `build-wine.sh` on a
`--without-vulkan` build (14 with Vulkan — `w1-win32u-vulkan-soname.patch` is
only needed when configure finds no Vulkan at all).

The apply step is built to be idempotent and to fail loudly:

- Each patch is tried forward, then reverse-probed to detect "already applied"
- Some patches overlap textually; those have explicit **guard clauses** that
  grep the source for a marker string instead of relying on the reverse probe
- `remove_obsolete_patch()` reverses out superseded patches
- A patch file listed but missing is a hard error, never a silent skip

Two rules learned the hard way, both documented in
[patches/README.md](../patches/README.md):

- **`maplestory-cx26-message-wait-handoff.patch` must stay out.** Upstream
  applies it to every CX26 build; here it makes the main thread spin on Cocoa
  events and freezes the game on UI clicks.
- **Patch filenames are provenance, not branding.** 11 keep a `cyder-` prefix
  from the pipeline this repo was forked from and are referenced by exact
  filename; the GAMMA rename deliberately left them alone.

`config/engine-release.json` records the patch list and lands in the release
manifest, so a shipped artifact says exactly what went into it.

## Conventions

**Paths.** Every script derives its root as `$SCRIPT_DIR/..`. `OGOM` is a
legacy alias for that root, still used inside `env-x86_64.sh`.

**Environment variables.** `GAMMA_*` is canonical. `CYDER_*` is accepted as a
fallback everywhere it used to exist, so engines and tooling from before the
rename keep working: `${GAMMA_X:-${CYDER_X:-default}}`. New variables should be
`GAMMA_*` only.

**Versioning.** `config/engine-version.txt` is the single source of truth for
the version label (e.g. `CX26.3.0-W11-Gamma086` at time of writing);
`config/engine-release.json`'s `versionLabel` mirrors it. The compact
artifact basename and sequence (e.g. `CX26W11-Gamma086-5`) used for the output filename are
no longer a separately hand-typed field — `gamma_engine_artifact_basename` in
`scripts/engine-common.sh` derives it mechanically from the label. See
[Versioning Policy](versioning-policy.md) for the exact format and what
triggers a bump.

**Signing.** Ad-hoc (`-`) by default, which is what local development and
end-user re-signing need. Release builds export
`SIGN_IDENTITY="Developer ID Application: …"`, which also switches on a secure
timestamp, since notarization rejects unstamped signatures.

**CrossOver.app** is auto-detected in `~/Applications` or `/Applications` only
as an optional MoltenVK source for a Vulkan-enabled Wine build. Renderer
staging never references it at runtime.

**Useful knobs.** `GAMMA_ENGINE_COMPRESS_LEVEL` trades archive size against
packing time (default `zstd -6`; `xz -6` is explicit compatibility mode); `GAMMA_SKIP_ENGINE_STRIP=1` and
`GAMMA_KEEP_DEBUG_SYMBOLS=1` help when debugging a packaged tree;
`--skip-renderers` builds Wine without staging any backend.

## Current state

- D3DMetal and DXMT are the only selectable backends
- D3DMetal is fixed to GPTK 4.0b2 and uses CrossOver's native directory layout
- The full patch sequence is verified to apply to a pristine CX 26.3.0 tree
  (15/15), but a complete from-scratch `build-wine.sh` run has not been
  re-timed since the patch-list fixes
