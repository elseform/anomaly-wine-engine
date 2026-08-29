# Things to try — D3DMetal 4.0b1 experience improvements

Research log, not a bug-fix plan. Target: GPTK 4.0b1 (`sources/gptk40b1`), D3DMetal backend.
Each entry: what it is, where it came from, why it might matter for this engine, status.

## Immediately actionable — no rebuild required

- **Set `GPTK_ROOT` directly, skip `install-renderers.sh` staging entirely for testing.**
  `runtime/cxcompatdb/cxcompatdb.c:492` already checks `$GPTK_ROOT/wine` as its
  *first* d3dmetal candidate, before `lib/d3dmetal`, the legacy `lib64/apple_gptk/wine`,
  or `lib/apple_gptk/wine`. b1's real on-disk layout is
  `sources/gptk40b1/d3dmetal/{wine,external}` (confirmed) — so
  `GPTK_ROOT=/Users/elseform/projects/2_2_gamma/gamma-wine-engine/sources/gptk40b1/d3dmetal`
  resolves to a valid `wine/` dir with no staging, no symlinks, no rebuild. This
  sidesteps the whole `GPTK_SRC` bug in `install-renderers.sh:29` for the purpose
  of just *testing* whether D3DMetal activates and clears the Options-menu repro —
  the real staging fix is still worth doing properly later for a packaged build,
  but this unblocks Checkpoint B today. Status: identified, untried — add
  `export GPTK_ROOT=".../sources/gptk40b1/d3dmetal"` to `app.env` and launch with
  `GAMMA_GRAPHICS_BACKEND=d3dmetal` to confirm.

## Env vars

- **`DXMT_ENABLE_NVEXT=0`** — disables DXMT's NVAPI extension shim. Source:
  lynkos blog, Palworld case — with NVEXT on, in-world scene doesn't render (HUD-only
  black screen). Relevant if DXMT is ever used as fallback/comparison against b1
  D3DMetal. Not yet in `app.env`. Status: untried.
- **`WINECPUMASK=0xff`** — pins/limits CPU affinity. Source: lynkos blog, Far Cry 3,
  flagged by the author as "performance gain?" — unverified claim, not measured.
  Status: untried, low confidence.
- **`WINE_LARGE_ADDRESS_AWARE=1`** — lets a 32-bit process address >2/4GB. Source:
  lynkos blog, Far Cry 3 / Oblivion Remastered crash fixes. `AnomalyDX11.exe` is a
  64-bit build, so likely moot for the main exe — worth checking only if some
  32-bit helper/launcher in the sss23 tree ever crashes with an OOM-shaped fault.
  Status: probably not applicable, keep in back pocket.
- **`D3DM_SUPPORT_DXR`** — official GPTK b2 README confirms default OFF on M1/M2,
  ON M3+; can force either way. Since b1 predates that documented default split,
  worth explicitly testing both values on-hardware rather than assuming b1 behaves
  the same. Status: untried on b1.

## Registry tweaks (Wine Mac Driver)

- **`RetinaMode=Y`** — `HKEY_CURRENT_USER\Software\Wine\Mac Driver\RetinaMode`.
  Source: lynkos blog (Schedule I, Far Cry 3). Enables HiDPI rendering instead of
  1x-then-upscaled. Worth trying if UI text/menus look soft.
- **`LogPixels`** — DPI value under the same key, paired with RetinaMode to offset
  scaling (216 or 254 in the blog's examples, monitor-PPI dependent). Only useful
  alongside RetinaMode.
- **`Decorated=N`** — same key, drops Wine's window chrome/border. Cosmetic only,
  useful if running borderless/fullscreen-style.

## Other projects worth mining further

- **WineForge** (`github.com/Alien4042x/WineForge`) — cloned full source tree
  (`sources/wine` equivalent, patched in-place, not separate `.patch` files) to
  `dlls/ntdll/unix/{d3dmetal_loader.c,dxmt_loader.c,wfdxcompat_loader.c}` +
  hooks in `loader.c`. Read all three directly. Findings, most interesting first:

  - **Per-process automatic backend override, independent of global config.**
    `loader.c` (`init_process_graphics_backend`, ~line 1170) keeps a hardcoded
    table of known launcher executables and forces a specific backend for them
    regardless of the user's `GRAPHICS_BACKEND`/`ACTIVE_GRAPHICS_BACKEND` setting:
    Battle.net (`battle.net.exe`, any args) and Ubisoft Connect's `upc.exe` (only
    when launched with `--in-process-gpu`) are forced to **DXMT**; Rockstar's
    launcher + Social Club helper are forced to **D3DMetal** (+ optionally their
    `WFDXCompat` frontend, see below). This is a real, general pattern worth
    stealing: exe-path-based (and even argv-based) per-process backend pinning,
    layered on top of whatever the global backend is. Our `cxcompatdb.c` currently
    only does one global backend selection per launch. If any bundled tool in the
    GAMMA/MO2 stack ever needs a different backend than the game itself, this is
    the shape to copy. Status: architecture worth adopting, no current known need.
  - **CEF/Chromium subprocess software-render fallback under DXMT.**
    `is_software_cef_process()` detects a subprocess launched with
    `--disable-gpu --disable-d3d11 --use-angle=swiftshader` and forces it off the
    Metal path entirely when the parent process's backend is DXMT
    (`process_uses_cef_software`, gates `d3dmetal_graphics_backend_enabled()` and
    `dxmt_graphics_backend_enabled()` both to FALSE for that subprocess). Workaround
    for embedded-Chromium launcher UIs colliding with the Metal translation layer.
    Only relevant if GAMMA/MO2 ever bundles a CEF-based helper UI. Status: noted,
    not currently applicable.
  - **`nvngx.dll` → `nvngx-on-metalfx.dll` fallback is automatic in their loader**
    (`d3dmetal_loader.c:resolve_d3dmetal_pe_path`) — tries the MetalFX-bridge name
    first, falls back to plain `nvngx.dll` only if that's missing. The official
    GPTK b2 README makes you do this rename by hand (see main README notes). Small,
    concrete patch idea: if we ever patch our own loader path resolution similarly,
    this removes a manual setup step. Status: nice-to-have, low priority.
  - **`D3DMETAL_RUNTIME_DIR` single-env-var pattern** — their equivalent of our
    `GPTK_ROOT`, pointing at a dir with `wine/x86_64-windows`, `wine/x86_64-unix`,
    and `external/libd3dshared.dylib` beneath it. Confirms the general design
    approach (env var over physical staging) is sound — reinforces the
    `GPTK_ROOT` finding above rather than adding anything new.
  - **`libd3dshared.dylib` "non-native code region" registration**
    (`init_d3dmetal_non_native_support`, loader.c ~line 1280) — on macOS 14+,
    dlopens `libd3dshared.dylib` and registers a JIT/executable-memory code region
    via `register_non_native_code_region`/`supports_non_native_code_regions`
    symbols. Looks like a Rosetta/D3DMetal code-signing or JIT accommodation.
    Unclear if CrossOver 26's own upstream D3DMetal integration already does this
    natively (plausible, since CX26 ships official D3DMetal support) — needs
    checking against `engine_root` (xray-monolith is the wrong place to look;
    this is Wine/CrossOver source, check the CX26 Wine tree itself) before
    assuming it's missing. Status: unconfirmed whether we already have this.
  - **DXMT covers 32-bit (`i386-windows`) explicitly** — `dxmt_loader.c`'s
    `dxmt_runtime_available()` requires `i386-windows/dxgi.dll`,
    `i386-windows/d3d11.dll`, `x86_64-unix/winemetal.so`. Confirms/matches our own
    app.env comment ("DXMT: the only Metal backend for 32-bit"), no new info, just
    cross-checked against real source instead of taking the comment on faith.
  - **`WFDXCompat`** — re-read against actual source, corrected from the earlier
    blog-derived summary: it's specifically a **D3D12 frontend swap**, not a
    general GDI-surface patch. `wfdxcompat_loader.c` intercepts `d3d12.dll` loads
    for processes on the Rockstar-launcher policy list and redirects them to their
    own `wfdx-launchers-v1.dll` + `wfdxbackend-d3d12.dll/.so` companion, gated on
    `WFDXCOMPAT_RUNTIME_DIR` (or derived from `D3DMETAL_RUNTIME_DIR` as a
    `wfdxcompat` sibling dir) actually containing those files. Only fires for
    Rockstar's launcher/Social Club helper. Not a general-purpose compat layer —
    narrower and more special-cased than the earlier summary suggested. Status:
    correction only, not actionable for us (no Rockstar launcher in this stack).
  - **DXMT module list note:** their DXMT covers `d3d10core.dll`, not plain
    `d3d10.dll` — corrects the earlier assumption in this doc that DXMT could
    directly fill b1's missing-`d3d10.dll` gap. `d3d10.dll` itself is a thin
    forwarder onto `d3d10core` in real Windows/Wine, so the gap-filling idea may
    still work, but it's `d3d10core.dll` doing the real work, worth confirming
    against our own DXMT payload's module list before relying on it.
  - 12 tracked CrossOver/CodeWeavers patch IDs (18947–26470, from the earlier
    blog-level pass) — not yet diffed against our own `sources/wine` patch set.
    Status: not diffed, lower priority than the findings above.

  Clone kept at
  `a temporary build directory` (session scratchpad, not in
  the repo) for further reading if needed — not committed anywhere.

## More projects, 2026-08-30 batch

- **`Gcenx/macports-wine`** — MacPorts overlay shipping prebuilt Wine 11.0
  (stable) / 11.16 (dev+staging), CrossOver 26.3.0 + winetricks wrapper,
  GPTK 1.1, GStreamer 1.28.1, MacOSX SDKs, mingw-w64-pkgconfig, libinotify —
  as installable ports instead of source builds. Our `scripts/build-wine.sh`
  builds everything from source against a manually-assembled toolchain
  (Homebrew bison/pkg-config, llvm-mingw, per `why-no-prebuilt-deps.md`'s
  stated reasoning for avoiding exactly this kind of prebuilt dependency).
  Genuinely worth reading *why* that doc rules out prebuilt deps before
  assuming this would help — if the reasoning was "no good prebuilt source
  existed," this may change that; if it was about reproducibility/control,
  it doesn't. Status: not evaluated against `why-no-prebuilt-deps.md`'s actual
  argument yet — read that doc first before considering this further. Their
  GPTK "1.1" version numbering doesn't match Apple's `4.0bX` scheme (probably
  their own overlay/port revision, not the GPTK build itself) — don't treat
  as a version signal without checking.
- **`vec715/enfusion-dxgi-fix`** — concrete, narrow bug + fix, real find.
  D3DMetal's `GetDisplayModeList()` returns **zero modes** for
  `DXGI_FORMAT_R16G16B16A16_FLOAT` (HDR format). Games that validate HDR
  support by checking for non-empty mode lists on that format reject the
  adapter as non-functional and refuse to start. Fix is a `dxgi.dll` proxy
  placed in the game directory: wraps factory/adapter/output objects,
  intercepts `GetDisplayModeList()`, and injects fallback resolutions when
  D3DMetal returns empty for that format. Targets Arma
  Reforger/DayZ (Enfusion engine, DX12), but the underlying D3DMetal bug is
  at the DXGI enumeration level, not engine-specific — worth checking if
  AnomalyDX11.exe (or MO2, or any DX9-11 tool in the stack) ever does an HDR
  capability probe and silently misbehaves under D3DMetal. Author notes
  rendering *still* crashes elsewhere in D3DMetal after this fix — so this
  patches one symptom, not a general D3DMetal reliability fix. Status: no
  known matching symptom in our stack yet, but the DXGI-proxy-DLL technique
  itself (wrap dxgi.dll, intercept specific calls, patch responses) is a
  reusable pattern if we ever need to work around a similar D3DMetal
  enumeration gap.
- **`gauthierpiarrette/highball-db`** — not code, a compatibility *database*
  (JSON, CC0-licensed) of Windows games on Apple Silicon via Wine + DXMT /
  D3DMetal / DXVK: verified-run status, community reports, anti-cheat
  blocklist, and a ProtonDB-derived prediction layer for ~12,500 untested
  titles. Worth checking for an existing Anomaly/GAMMA/S.T.A.L.K.E.R. entry
  or similar X-Ray-engine title before assuming we're the first to hit a
  given bug — and worth contributing our own findings back given the
  permissive license. Status: not queried yet.
- **`Alien4042x/BottleForge`** — same author as WineForge. A GUI, "winetricks
  for macOS," for CrossOver/CXPatcher bottles — not a source tree, a
  companion app. Exposes the same D3DM_* knobs (Metal HUD, MetalFX, DXR, FPS
  cap, Metal 4 backend) through a UI instead of env vars in `app.env`. Early
  development. Nothing to pull into our engine architecturally — noted as a
  possible testing-convenience tool only, not a code source.
- **`zzzz465/homebrew-wine-dxmt`** — bundles Wine Staging 11.8 + DXMT v0.80 +
  automated Steam install into one installer, with patches for Steam UI
  compat, resolution-change handling, and video rendering (fixes DJMax
  specifically). Our own `scripts/fetch-dxmt.sh` pins DXMT by commit SHA, not
  a version tag, so "v0.80" isn't directly comparable without resolving what
  commit that tag corresponds to. The resolution-change and video-rendering
  patches are generic-enough Wine/DXMT pain points that they might apply
  beyond Steam specifically — worth reading their actual patch diffs if we
  ever hit either symptom. Status: not read in detail, flagged by category
  only.

## Confirmed-but-already-known (no action, just cross-refs)

- `WINEDLLOVERRIDES="dinput8=n,b;d3d11,d3d10,d3d12,dxgi=b"` pattern (lynkos blog) —
  matches the reasoning already in the main plan (Phase 0 decision #3): set
  renderer DLLs to `builtin`, let `cxcompatdb` do backend selection via search-path,
  don't fight it with forced native overrides.
- `D3DM_ENABLE_METALFX`, `D3DM_MTL4`, `D3DM_MAX_FPS`, `ROSETTA_ADVERTISE_AVX` —
  official GPTK b2 README semantics already folded into `app.env` comments.
