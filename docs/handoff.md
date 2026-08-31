# Handoff — 2026-08-30

Snapshot for resuming this work another day. Supersede/replace this file
next session rather than letting it drift — treat it as a pointer to
current state, not permanent history (that lives in git log and the other
docs referenced below).

## Where things actually stand

- **Target confirmed: GPTK 4.0b1**, not b2. b1 is the only payload proven
  playable; b2 has a real, confirmed, GPTK-internal bug (see
  `docs/d3dmetal-savegame-crash.md` — resolved via direct A/B test, not
  guessed).
- **Full clean rebuild done and verified.** `install/wine-cx26-x86_64/version`
  now reads `CX26.3.0-W11-Gamma005`, matching `config/engine-version.txt`
  exactly — no more patch-application uncertainty. All 15 active patches
  audited individually, confirmed real and doing what their names claim.
- **Fresh artifact packed and tested end to end.**
  `dist/artifacts/CX26W11Gamma005.tar.xz` (built from the current rebuild,
  not a stale pre-fix pack) contains the full b1 D3DMetal payload, DXMT,
  DXVK (staged but inactive — no MoltenVK, `--without-vulkan` build), and
  the complete redist DLL set, self-contained.
- **`scripts/interactive-setup.sh` confirmed working against the fresh
  build.** Ran it end to end (piped input — see gotcha below), produced
  `~/Applications/GAMMA.app` + a fresh prefix at
  `~/Library/Application Support/GAMMA/prefix`. Log confirms the real win:
  ```
  gamma-cxcompatdb:info: graphics backend=d3dmetal machine=x86_64-windows path=.../lib/d3dmetal
  ```
  **D3DMetal actually activates** for the 64-bit path (where
  `AnomalyDX11.exe` lives) — this is Checkpoint B from the working plan,
  now passed. 32-bit subprocess correctly falls through to DXMT instead
  (GPTK ships no i386 payload — expected, documented).
- **Game launch confirmed under D3DMetal b1.** In-game, working. Checkpoint
  C passed.
- **DXMT retested, still broken — crashes on game load.** Consistent with
  the unresolved startup crash already documented in `renderers.md`
  (status as of 2026-08-26), not a new bug and not the savegame bug. The
  rebuild/engine patches did not fix it. D3DMetal b1 remains the only
  working backend for this engine.

## Fixed this session (all pushed, `origin/main` at `10cbb02`)

- `scripts/install-renderers.sh`: `GPTK_SRC` default reverted from a
  drifted `sources/gptk40b2` back to `sources/gptk40b1/d3dmetal` (correct
  nested path for b1's layout).
- `scripts/interactive-setup.sh`: dropped the `d3d11`/`dxgi`/`d3d12` →
  `builtin` DllOverrides loop that was fighting `cxcompatdb.so`'s own
  search-path-based backend activation. Also dropped a dead
  `CX_APPLEGPT_LIBD3DSHARED_PATH` typo (missing the K) in the generated
  launcher — harmless, just noise.
- `patches/cyder-ntdll-query-directory-object-trace.patch` moved into
  `patches/obsolete/` where it belongs (confirmed: only ever reversed by
  `remove_obsolete_patch()`, never applied — file location just didn't
  match its role). `build-wine.sh`'s reference path fixed to match.
- Committed real prior work that was sitting untracked: the full
  `d3dmetal-savegame-crash.md` investigation (resolved), both
  `runtime/d3dx11-safe-shim/` (real, harmless safety net) and
  `runtime/d3d11-format-rewrite-shim/` (paused/unconfirmed lead, kept as
  reference only — not wired into the build).
- `dist/artifacts/`: stale/broken artifacts (old Gamma001-004, stale
  `_bak`, old `.tar.zst`) moved (not deleted) to
  `agents_backups/gamma-wine-engine/dist/artifacts/2026-08-30/`.

## Gotcha for next time: piping `interactive-setup.sh`

It's 7 sequential prompts in this order — artifact path, app name, app
dir, game root, **exe path relative to game root**, backend choice,
confirm. Get the blank-line count wrong before the exe-path prompt and it
silently shifts every answer by one, which sends it into an infinite
"Not found" retry loop reading from closed stdin (hit this once tonight,
had to `kill` it — no damage done, it dies before ever touching disk, but
don't assume a piped run finished just because the background task
reports exit 0 — read the actual log).

## Real next steps, roughly in order

1. **Macports sanity check** (user's idea, explicitly deferred, not
   started): try `Gcenx/macports-wine` as a completely separate build path
   — prebuilt Wine 11.0/11.16 + CrossOver 26.3.0 + GPTK 1.1 via MacPorts —
   purely to see if it happens to have DXMT + D3DMetal 4.0b1 *and* b2 all
   working out of the box. Low-effort, "would be funny if it just worked,"
   not a real expectation.
2. `docs/things-to-try.md` has a running list of env vars, patches, and
   ideas gathered from official docs, blog posts, and WineForge source —
   not bug-fixing, just experience-improvement ideas for b1. Worth
   revisiting when there's time to actually test some of them (the
   `GPTK_ROOT` shortcut env var is already confirmed real and useful —
   see that file's top entry).
3. `d3dx11-safe-shim`: confirmed unnecessary on b1 — savegame thumbnails
   work fine as-is, the null-texture-pointer bug it guards against was
   only ever observed on b2. Not wiring into `interactive-setup.sh`. Kept
   in `runtime/d3dx11-safe-shim/` as reference only, in case a future GPTK
   update reintroduces the underlying bug. Was: manual
   `bash build.sh && bash install.sh "$WINEPREFIX"` step, still available
   if ever needed, just not part of the standard setup path.

## Prompt to paste next session

> Resume gamma-wine-engine work. Read `docs/handoff.md` first for current
> state — core investigation is closed: D3DMetal b1 confirmed working
> end-to-end (launch, in-game, savegame thumbnail all fine),
> `~/Applications/GAMMA.app` exists with a working prefix, DXMT confirmed
> still broken (crashes on game load, matches `renderers.md`'s existing
> unresolved entry), `d3dx11-safe-shim` confirmed unnecessary on b1. What's
> left is low-priority/optional: the Macports sanity check and picking
> items from `docs/things-to-try.md` to test. Don't re-derive anything
> already confirmed in this doc, `docs/d3dmetal-savegame-crash.md`, or
> `docs/renderers.md` — start from where it left off.
