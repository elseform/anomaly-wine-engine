# Known issue: D3DMetal crashes saving the game (RESOLVED — use GPTK 40b1, not 40b2)

**Status: resolved 2026-08-30.** Root cause confirmed via direct A/B test,
not just inferred: **GPTK 4.0b1 does not have this bug; 4.0b2 does.**
Same engine build, same `d3d11_orig.dll`/no-shim state, swapped only
`sources/gptk40b1/d3dmetal` in for `sources/gptk40b2` (`GPTK_SRC` in
`install-renderers.sh`, plus — important, easy to miss — `lib/external`
needs re-syncing too, not just `lib/d3dmetal`; the Metal HUD's own "Game
Porting Toolkit" version line is the fast way to confirm which one is
actually loaded, `D3DMetal.framework/Versions/A/Resources/version.plist`'s
`CFBundleShortVersionString` is the ground truth). Game reached the actual
main-menu/gameplay stage cleanly (artifact/condition data loading, not the
"No valid renderer" loop b2 hit) and **saved with no crash**.

b1's only real cost — missing `d3d10.dll` (Apple never shipped it in that
beta) — doesn't matter for this game: confirmed from source
(`Layers/xrRenderDX10/dx10Texture.cpp`) that `AnomalyDX11.exe` compiles with
`USE_DX11` defined, so every `D3DX10*`-guarded branch in that file compiles
out entirely; only `D3DX11*` calls (covered by `d3d11.dll`, present in b1)
ever execute in this exe. b2 is otherwise reported as noticeably better —
performance and visual quality — so this is a real tradeoff, not a free
win; worth deciding per-install whether the reliability of b1 or the
quality of b2 (once its actual bug is fixed upstream by Apple) matters more.

**All of the investigation below (Leads A-E, the two shims) was run against
b2** — kept for reference since none of it is wasted: Lead E's Wine-tree
rebuild, the `d3dx11-safe-shim`, and the `d3d11-format-rewrite-shim` remain
valid, reusable techniques for other GPTK-payload bugs, and the underlying
`__wine_syscall_dispatcher` livelock (Lead E) is a real, separate, upstream
Wine bug unrelated to which GPTK beta is in use. DXMT's separate,
still-unresolved startup crash is documented in
[renderers.md](renderers.md) — a different bug with a different signature;
don't conflate the two.

## Symptom

Game runs fine under D3DMetal — menus, level load, normal play all clean.
Crashes specifically on writing a savegame, with a screenshot for the save
slot's thumbnail. Reproduced identically across:

- GPTK `40b1` and `40b2` (`sources/gptk40b1/d3dmetal` vs `sources/gptk40b2`)
- with and without the engine's `-dxgi-old` compatibility flag
- `d3dx11_43` DllOverride `native,builtin` (real Microsoft DLL) vs a
  from-scratch proxy DLL that null-checks its texture arguments (see below)
- with `D3DM_ERROR_MODE=1`, `D3DM_BOUNDS_CHECK=1`, `D3DM_LOGLEVEL_INFO=1` all
  enabled — produced **zero** additional D3DMetal-side diagnostic output
  around the crash. **Caveat, found after the fact**: these three variable
  names are unconfirmed — not proven fake, just not found in any source
  checked so far. This engine targets GPTK 4 (`sources/gptk40b1`/`gptk40b2`),
  and GPTK 4's *documented* env-var surface uses a different namespace
  entirely — its CLI wrapper uses `GPTK4_BOTTLE`/`GPTK4_MAX_FPS`, not
  `D3DM_*` — which doesn't confirm or deny the internal `D3DM_*` vars
  `app.env` uses, but does show at least one clear namespace mix-up already
  present in that file (`app.env` has `D3DM_MAX_FPS`, not `GPTK4_MAX_FPS`).
  Treat `app.env`'s `D3DM_*` block past `D3DM_SUPPORT_DXR` (confirmed real,
  Apple's GPTK 2.1 README) and `D3DM_ENABLE_METALFX` (in real use elsewhere
  in this codebase) as **unverified, not confirmed fake** — worth checking
  each one properly, separate from this specific crash.

Every attempt produced byte-identical crash offsets (`d3dx11_43+0x37203`,
called from `+0x1505d`, called from `+0x16090`, called from
`anomalydx11+0xba49da`) — this is a single, deterministic bug, not a race.

## Root call site

`Layers/xrRender/r__screenshot.cpp`, `CRender::ScreenshotImpl`,
`SM_FOR_GAMESAVE` case (~line 64-111):

```cpp
D3D_TEXTURE2D_DESC desc;
ZeroMemory(&desc, sizeof(desc));
desc.Width = GAMESAVE_SIZE;              // 128 — block-aligned, not the issue
desc.Height = GAMESAVE_SIZE;
desc.MipLevels = 1;
desc.ArraySize = 1;
desc.Format = DXGI_FORMAT_BC1_UNORM;     // compressed format
desc.SampleDesc.Count = 1;
desc.Usage = D3D_USAGE_DEFAULT;
desc.BindFlags = D3D10_BIND_SHADER_RESOURCE;
CHK_DX(HW.pDevice->CreateTexture2D( &desc, NULL, &pSrcSmallTexture ));

CHK_DX(D3DX11LoadTextureFromTexture(HW.pContext, pSrcTexture,
    NULL, pSrcSmallTexture ));           // <- crash happens somewhere in
                                          //    this call or the next one

HRESULT hr = D3DX11SaveTextureToMemory(HW.pContext, pSrcSmallTexture,
    D3DX11_IFF_DDS, &saved, 0);
```

`CHK_DX` only checks the `HRESULT` from `CreateTexture2D` — never whether
`pSrcSmallTexture` itself came back as a valid, fully-formed object. Format is
hardcoded `D3DX11_IFF_DDS` for this specific save-thumbnail path (the
JPG/PNG/BMP options in the same file only apply to the *other* screenshot
mode, manual screenshots — not configurable for saves without an
xray-monolith rebuild).

## Crash signature detail

```
Unhandled exception: page fault on read access to 0x0 in 64-bit code
rax=0 rcx=0  (both zero at the fault instruction)
=>0 d3dx11_43+0x37203
  1 d3dx11_43+0x1505d
  2 d3dx11_43+0x16090
  3 anomalydx11+0xba49da   <- game's call site, identical every run
```

`rcx=0` at the fault strongly suggests a null COM `this` pointer being
dereferenced for a vtable method call, 2-3 internal calls deep inside
whichever D3DX11 utility function this resolves to (not confirmed which —
see attempt 3 below).

## Attempts made, all unsuccessful

1. **Force `d3dx11_43` to Wine's builtin implementation.** Discovered Wine's
   own `D3DX11SaveTextureToMemory`/`D3DX11LoadTextureFromTexture` are pure
   `E_NOTIMPL` stubs (`dlls/d3dx11_43/texture.c`) — would have been a safe
   no-crash workaround if it had loaded, but the registry override never
   actually took effect (confirmed via file-hash comparison: the loaded DLL
   was still the native one, byte-identical crash). Cause of the override not
   taking effect wasn't fully diagnosed — deprioritized once the stub-only
   nature of Wine's implementation was found, since even a working override
   would only mask the crash (return `E_NOTIMPL`), not fix the underlying bug.

2. **Remove `-dxgi-old`.** Hypothesis: the engine's own comment above the
   `dxgi_old` branch in `dx10HW.cpp` (~line 683) says the
   `ResizeTarget → ResizeBuffers → UpdateViews` sequence is "required to get
   the default render target to match the swap chain resolution" — and
   `dxgi_old` skips `ResizeBuffers` at device init, going straight to
   `UpdateViews()`. Since `pBaseRT` (what the screenshot code reads via
   `HW.pBaseRT->GetResource(&pSrcTexture)`) is set up differently depending on
   this flag, a stale/mismatched `pBaseRT` under D3DMetal's own DXGI
   implementation seemed plausible. **Ruled out**: identical crash with the
   flag removed. Restored to the working install afterward.

3. **Proxy `d3dx11_43.dll` with top-level null-checks.** Built with the
   engine's own llvm-mingw toolchain — see `runtime/d3dx11-safe-shim/`. Null-
   checks `src_texture`/`dst_texture`/`texture` arguments on
   `D3DX11LoadTextureFromTexture`, `D3DX11SaveTextureToMemory`,
   `D3DX11SaveTextureToFileA`/`W` before forwarding to the renamed real DLL
   (`d3dx11_43_orig.dll`); all 29 other exports are untouched PE forwarders.
   Confirmed to load correctly and cause no regression in normal (non-save)
   texture loading. **Did not fix the crash** — identical signature,
   `d3dx11_43_orig` called directly from the same game address with no
   shim frame visible. Two explanations, not yet distinguished:
   - `-O2` tail-call-optimized the shim's `return fn(...)` into a `jmp`,
     erasing its own stack frame — the null-check may have run and passed
     (arguments genuinely non-null) before jumping into the real DLL.
   - The actual crashing D3D11 export isn't one of the 4 intercepted
     functions at all — `anomalydx11+0xba49da`'s target was inferred from
     reading the source, not confirmed by disassembly.
   Either way, this establishes: **if** the top-level `pSrcSmallTexture`
   pointer itself were null, this fix should have caught it. It didn't, so
   either the pointer is non-null-but-internally-broken, or a different
   function than assumed is involved.

## Lead E — this may not be a bug in this crash's code at all: Wine-build/GPTK-payload ABI mismatch

**Found late in this investigation, via Whisky's own issue tracker
(frankea/Whisky#163) — likely supersedes Leads A-C below.** `D3DMetal`'s
`libd3dshared.dylib` doesn't call standard Wine APIs at all: it works by
*patching Wine's internal unixcall dispatch machinery at load time*, against
the exact internal memory layout of whatever CrossOver-derived Wine build it
was compiled against (confirmed via `nm` on the payload by Whisky
contributor `dappermint` — zero Wine imports, but exports
`PatchUnixCallTable()`, `WineRegistry::Init`, `WineMonitor::Init`, a
`WineEventCallbacks` dispatch surface). On a Wine tree whose internal shape
has drifted from what the payload expects, the patch handshake silently
fails and Apple's code throws down an error path that terminates inside
Wine's unimplemented `virtual_unwind` personality-routine handler — same
disease reported to cause a Unity game to die at `GfxDevice: creating device
client` and Steam.exe to stack-overflow in Apple's DXGI, "different thread"
of the same root cause each time.

This matches our symptom shape better than any DirectX-level explanation:
crashes several calls deep inside seemingly-unrelated code, no top-level
argument ever actually null under inspection, unfixable by null-checking
because the actual failure is a structural ABI mismatch, not a bad argument.

**dappermint independently built and confirmed a fix — corrected understanding**:
an early experiment used Wine 10.0/CrossOver 25 (mentioned in the Whisky
issue thread), but the current, maintained recipe
([dappermint/winecx-gptk](https://github.com/dappermint/winecx-gptk)) is
different and better-targeted: **CrossOver 26.3's Wine diff — the same
CrossOver version this engine already builds from — rebased onto newer
upstream Wine (11.15, then 11.16)**, maintained as a public branch
(`dappermint/winecx`, `wine1116` branch) with every patch already merged
into the tree (`patches/` in `winecx-gptk` is empty on purpose). Fully
public, no CodeWeavers download required. Confirmed working: Steam's UI end
to end, D3D12 through D3DMetal at feature level 12_2, DXVK D3D11, msync, and
the media stack, measured on an M5.

**So the fix isn't "downgrade CrossOver version"** — it's "use the CrossOver
26.3 diff kept in sync with current upstream Wine via a maintained public
fork, rather than building from the raw, unmodified
`crossover-sources-26.3.0.tar.gz` directly." One more relevant difference
from their README: they build the PE half with `mingw-w64 gcc`, not
`llvm-mingw` — found that an llvm-built `kernelbase.dll` stalls Steam's CM
login by module bisection. `gamma-wine-engine` uses `llvm-mingw`
exclusively — a second, independent toolchain-level variable worth isolating
separately from the source-tree question, since it's a different plausible
cause of subtle runtime bugs in this exact build ecosystem.

**Tested — does not fix this specific crash.** Cloned `dappermint/winecx` at
the `wine1116` branch (CrossOver 26.3's diff rebased onto current upstream
Wine 11.16) and rebuilt `gamma-wine-engine` against it in full: 12 of the 15
custom patches applied cleanly, 1 was already present upstream, 2 needed
skipping (unrelated to rendering — macOS window OpenGL view-sync, wineserver
diagnostics edge cases). Along the way, caught and fixed a real cross-patch
bug: `cyder-wineserver-add-completion-guard` calls `wineserver_diag_printf`,
which only `cyder-wineserver-exit-diagnostics` (initially skipped) actually
defines — build failed loudly at compile time, both patches' hunks were
manually re-applied against the new tree's context, verified against the
pristine clone to confirm no stray corruption. Full rebuild succeeded,
packaged, fresh test app bootstrapped, GAMMA launched under D3DMetal, save
attempted.

**Result: identical crash.** `Unhandled page fault ... at address
00006FFFFEA67203`, module base `6ffffea30000` — same `+0x37203` offset as
every single crash tonight, on stock CrossOver 26.3.0/Wine 11.0 *and* now on
this CrossOver 26.3/Wine 11.16 rebuild. Confirmed this was actually testing
the new engine, not a stale run (module name is plain `d3dx11_43`, no
`_orig` suffix — the fresh prefix has no shim installed, unlike the earlier
tree).

**What this actually tells us**: the Wine-tree-ABI-mismatch theory explains
real, separately-confirmed symptoms (Steam's UI failing to paint, Unity
dying at device creation on the older tree) — but this specific
BC1-thumbnail-compression crash isn't one of them. It reproduces
identically regardless of which Wine tree hosts the GPTK 4.0b2 payload,
which points at the bug being **inside GPTK 4.0b2's D3DMetal implementation
itself** (on-the-fly BC1 compression specifically), not a Wine-side issue at
all. Apple's to fix, same category as the D3DM_MTL4/D3D12 deadlock
(frankea/Whisky#229) — not something reachable by changing which Wine tree
hosts the payload.

**Given that, Leads A-C below become the real path forward** — specifically
Lead C (rewrite the texture format to sidestep BC1 compression entirely) is
now the most promising, since it avoids the buggy GPTK code path rather than
trying to out-version it. `D3DM_MTL4` (raised as a possible lever earlier,
see Lead B below) remains confirmed irrelevant — it gates GPTK4's D3D12
submission path specifically, and `AnomalyDX11.exe` never touches D3D12.

## Leads A-D (narrower Wine-side leads — now the live options, since Lead E's rebuild didn't fix it)

Ranked by expected effort vs. confidence, not strict priority — the cheapest
one (B) is worth trying first regardless of confidence, since it costs
nothing to test. Kept for completeness and because Lead E hasn't been
tested yet — if the CrossOver-25 rebuild doesn't fix it, these remain live.

### Lead A — Confirm which export actually crashes, then re-target the shim

Attempt 3 assumed the crash is inside `D3DX11LoadTextureFromTexture` or
`D3DX11SaveTextureToMemory` based on reading `r__screenshot.cpp`, but never
confirmed this by disassembly. Real export RVAs from
`d3dx11_43_orig.dll` (via `objdump -p`):
`D3DX11LoadTextureFromTexture=0x123b4`, `D3DX11SaveTextureToMemory=0x16008`,
`D3DX11SaveTextureToFileA=0x15e78`. The crash chain's frame-2 address
(`+0x16090`) is suspiciously close to `D3DX11SaveTextureToMemory`'s RVA
(`0x16008` — only `0x88` bytes apart), which is consistent with frame 2 being
a few instructions *into* `D3DX11SaveTextureToMemory` after entry, not a
separate internal helper reached from a different export. That actually
supports the original assumption rather than contradicting it — meaning
explanation 1 (tail-call frame elision) is the more likely of the two, not
explanation 2. **Next step**: disassemble `D3DX11SaveTextureToMemory` at
`0x16008` directly (`objdump -d --start-address=0x16008 --stop-address=0x16200`)
to see what it does in its first ~0x88 bytes before reaching the offset that
lines up with frame 2, confirming or refuting this. If confirmed, the shim's
null-check logic needs to go deeper than the top-level pointer — likely
checking the result of an internal `GetDevice()`/`QueryInterface()` call on
`pSrcSmallTexture` (see Lead C), since the top-level pointer passing our
check but something *it points to* being null is the remaining explanation.

### Lead B — Get a real diagnostic capture, via the actually-current tooling

`D3DM_MTL4` isn't in this lead anymore — one of the `app.env` variables now
flagged unverified above, dropped rather than built a lead on an unconfirmed
name. Two real options, in order of how current they are:

- **`gpucapture`/`gpudebug`** — macOS's current Metal debugging tools for
  exactly this GPTK4-era toolchain (this session has dedicated skills for
  both: `using-gpucapture` to capture a `.gputrace` of the game process
  around the save action, `using-gpudebug` to inspect it — draw calls,
  resource bindings, pipeline state, the actual texture object in question).
  This is the right tool for "what does D3DMetal actually do when this
  texture gets created," not env-var guessing.
- Older fallback if the above doesn't apply cleanly to a Wine-hosted
  process: `D3DM_DXIL_PROCESS_DEBUG_INFORMATION=1` + `MTL_CAPTURE_ENABLED=1`
  (both confirmed in Apple's GPTK 2.1 README) — narrower, GPTK-3-and-earlier
  era, but a real documented pair, unlike the three that produced silence.

Either gets a real capture instead of continuing to infer from bare
instruction offsets — the only lead of the three that directly answers
Lead A's open question (which export/internal call is really failing)
without more guessing.

### Lead C — Sidestep the bug: rewrite the format instead of chasing the null

Rather than continuing to find and null-check whatever internal pointer is
actually null, avoid the problematic call shape entirely. The screenshot
code's `CreateTexture2D` call is easy to identify by its exact signature
(128×128, `DXGI_FORMAT_BC1_UNORM`, `D3D_USAGE_DEFAULT`,
`BindFlags=D3D10_BIND_SHADER_RESOURCE` only, 1 mip, 1 array slice — a very
specific, matchable pattern unlikely to collide with any other texture the
engine creates). A Wine-side hook on `ID3D11Device::CreateTexture2D` (via a
vtable detour on `HW.pDevice`, or a full `d3d11.dll` proxy analogous to the
`d3dx11_43` one) that rewrites `desc.Format` from `DXGI_FORMAT_BC1_UNORM` to
`DXGI_FORMAT_R8G8B8A8_UNORM` for exactly this creation pattern would let
D3DMetal create an uncompressed texture instead — sidestepping whatever gap
exists in its on-the-fly BC1 compression path, at the cost of a slightly
larger savegame thumbnail (128×128 RGBA8 ≈ 64KB vs. BC1's ≈ 8KB — trivial for
a savegame file). `D3DX11SaveTextureToMemory(..., D3DX11_IFF_DDS, ...)` on an
uncompressed texture is a well-supported DDS path, not a corner case.
**More implementation work than A or B**: `CreateTexture2D` is a COM vtable
method, not a flat DLL export, so this needs a proper vtable-pointer detour
(intercepting `HW.pDevice`'s vtable slot after device creation) rather than
the export-forwarding technique `d3dx11-safe-shim` used — a different, more
invasive technique, but the most likely of the three to actually resolve the
crash rather than just relocate it, since it avoids the buggy path instead of
guessing where inside it things go wrong.

### Lead D — Cross-thread race between save-serialization and screenshot capture (checked, mostly ruled out for this exact path)

Raised as a hypothesis: maybe not a DirectX bug at all, but a threading race
that happens to manifest inside a D3D call — two things (save-write,
screenshot-capture) happening at once. Worth checking seriously given
tonight's *other*, independently-confirmed crash in this same engine (DXMT's
startup crash, `docs/renderers.md`) already involves a `concrt140` worker
thread racing D3D calls, and this codebase has a dedicated patch
(`gamma-ntdll-flush-write-buffers-sync.patch`) specifically for
Rosetta-2 thread-stall bugs — a second, independent race wouldn't be a
stretch in this environment.

**Traced the actual call path and it doesn't hold up, at least not here.**
`console_commands.cpp` (~line 1136-1156, the manual-save console command):
`Level().Send(net_packet, M_SAVE_GAME)` runs **before**
`MainMenu()->Screenshot(SM_FOR_GAMESAVE, ...)` on the next line — but that
`Send()` call doesn't return until save-serialization is *fully done*.
Traced it down: `M_SAVE_GAME` → `Level_network_messages.cpp` →
`CLevel::ClientSave()` (`Level_network.cpp:275`) — a plain synchronous
`for(;;)` loop building and sending packets, no thread/task spawned
anywhere in that file (checked directly, no `concrt`/`std::thread`/
`std::async`/`task_group`/`CreateThread` in `Level_network.cpp`). By the
time `Send()` returns, the loop has already completed. The screenshot flag
that `MainMenu()->Screenshot()` sets doesn't even get processed until
`Device.dwFrame + 1` (`MainMenu.cpp` `OnFrame()`), meaning: for a **manual
save via console command**, save-serialization finishes on the main thread
before the screenshot is even queued — no overlap, this specific path is
sequential, not racing.

**Not fully closed**: this only traces the manual-save path. `autosave_manager.cpp`
also calls `MainMenu()->Screenshot(SM_FOR_GAMESAVE, ...)` — worth checking
separately whether autosave's trigger path differs (e.g. fires mid-gameplay
while other systems are already using `concrt140` for level streaming/async
loading, unlike a menu-triggered manual save where the game is likely
otherwise idle). All backtraces collected tonight were from **manual**
saves, so this lead is downgraded from "likely" to "checked and ruled out
for the manual-save path specifically" — not dead for autosave, just
unconfirmed there.

## Lead C attempt — built, blocked by unrelated complications (paused, not resolved)

Built `runtime/d3d11-format-rewrite-shim/`: a proxy `d3d11.dll` placed in
`lib/d3dmetal/x86_64-windows/` (GPTK's actual `d3d11.dll` is loaded from
there via `cxcompatdb`'s directory-prepend, not `system32`/registry override
— a different mechanism than the `d3dx11_43` shim used). Wraps
`D3D11CreateDevice`/`D3D11CreateDeviceAndSwapChain`, and after a real device
is created, patches its vtable slot 5 (`CreateTexture2D` — confirmed against
Wine's own `d3d11.idl`: `ID3D11Device : IUnknown` directly, so
`QueryInterface=0, AddRef=1, Release=2, CreateBuffer=3, CreateTexture1D=4,
CreateTexture2D=5`) via a one-time `VirtualProtect` + pointer swap on the
shared vtable array. Trampoline rewrites `DXGI_FORMAT_BC1_UNORM` to
`DXGI_FORMAT_R8G8B8A8_UNORM` only for creation requests matching the exact
signature the savegame-thumbnail code uses (128×128, 1 mip, 1 array slice,
`D3D11_USAGE_DEFAULT`, `BindFlags=D3D11_BIND_SHADER_RESOURCE` only).

**First real blocker, found and fixed**: `cxcompatdb`'s own
`pe_is_builtin_for_machine()` requires the literal ASCII marker
`"Wine builtin DLL"` at DOS-header byte offset 64 before accepting any
candidate in `lib/d3dmetal`/`lib/dxmt` — every genuine Wine/GPTK DLL there
carries it (confirmed byte-for-byte against the real `d3d11_orig.dll`); a
plain `llvm-mingw` build doesn't, and was silently rejected
(`invalid PE machine/signature or symlink`) with a fallback to DXMT instead
of a clear error — which is what actually caused the "not running" confusion
initially (DXMT's own unrelated crash fired instead). Fixed: `build.sh` now
patches this marker into the compiled DLL automatically.

**Second complication**: with the marker fixed, the shim loaded and the game
booted — but then hung on the splash screen. Sampled the live process:
confirmed the *exact same* `__wine_syscall_dispatcher` recursive-spin
livelock from `wine_11.16` (see Lead E above, still unfixed upstream) — a
genuine pre-existing race, not new. But a same-vs-different comparison (real
`d3d11.dll` restored = loaded clean; shim installed = hung twice in a row)
suggested a possible correlation: the shim's per-call `GetProcAddress` and
the one-time `VirtualProtect` are extra syscalls landing in the same
sensitive window multiple threads spawn in, which could plausibly shift
timing enough to hit the race window more often. Not proven — small sample —
but real enough to fix regardless: `build.sh`/`shim.c` updated to cache the
resolved function pointers instead of calling `GetProcAddress` on every
invocation.

**Third complication, where this got paused**: after the caching fix, a
*different* failure appeared — `CEngineAPI::CreateRendererList`: "No valid
renderer found," looping continuously (confirmed both from the game's own
log, timestamped live, and directly observed by the user). Traced to a real,
independent bug in the engine itself:
`Layers/xrRenderPC_R4/r2_test_hw.cpp`'s `TestDX11Present()` — a DX11
capability probe run before the real renderer initializes — registers a
window class (`"TestDX11WindowClass"`) but **never unregisters it**
(`RegisterClassEx` call at line 48, no matching `UnregisterClass` anywhere
in the function, confirmed by reading the full function body). Harmless on
a single successful probe, but if this probe runs more than once in the
same process (which the repeating log confirms is happening now, however it
got triggered), the second attempt fails at `RegisterClassEx` with the
class already registered — masking whatever caused the *first* attempt to
fail in the first place. The one first-attempt failure captured before the
loop drowned it out: `D3D11: device creation failed with hr=0x80004005`
(`E_FAIL`) — notably the exact literal fallback value my shim's own
error paths return, raising the question of whether the shim's
`D3D11CreateDeviceAndSwapChain` is even the code actually running for this
specific probe call. Added `fopen`-based file logging
(`Z:\tmp\d3d11_shim_debug.txt`) directly inside the shim's entry points to
settle this — **the debug file never got created on the next run**, meaning
the shim's own instrumented code path wasn't hit at all for this call,
despite `cxcompatdb` consistently reporting `backend=d3dmetal` resolved to
the right directory throughout. Not yet explained — plausible causes not yet
distinguished: Windows deduplicates `LoadLibrary` by module name (if
`d3d11.dll` got loaded into the process earlier via a different path before
this probe runs, `LoadLibrary("d3d11.dll")` here would just return that
already-loaded handle rather than hitting the shim fresh); or something in
how this specific early test-probe context resolves module names differs
from the main renderer's own device-creation path (which — unverified,
logs were overwritten by later runs — may or may not have actually
exercised the shim successfully in the earlier "reached splash screen"
tests either).

**Paused here, not resolved.** Three genuinely separate things are now
tangled together for this specific approach: the confirmed-independent
Wine-core livelock (Lead E), a real and previously-unknown engine bug in
`TestDX11Present()`'s missing cleanup, and an unconfirmed question about
whether the shim is even in the call path for this specific probe. Next
session should settle the "is the shim actually loaded here" question first
(the debug-file test above, rerun and actually checked) before assuming
anything else about Lead C's viability.

## Reference: shim source

`runtime/d3dx11-safe-shim/` — `shim.c`, `d3dx11_43.def`, `build.sh`,
`install.sh`. Builds with the engine's own llvm-mingw toolchain
(`build/llvm-mingw-*/bin/x86_64-w64-mingw32-clang`). Currently installed in
the `GAMMA-Engine.app` test prefix; harmless to leave in place (no regression
observed) even though it didn't fix this specific crash — it's still a
legitimate safety net for any *other* null-texture case that might reach
these same functions.
