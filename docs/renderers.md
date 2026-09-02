# Graphics Backends

The engine ships several Direct3D implementations side by side and picks one at
process start. Selection is done by `cxcompatdb.so`, a small unix-side plugin
built from `runtime/cxcompatdb/cxcompatdb.c` and loaded by CrossOver's `ntdll`.

## Tree layout

```
lib/wine/x86_64-windows/   Wine builtins, plus winemetal.dll
lib/wine/i386-windows/     Wine builtins, plus winemetal.dll
lib/wine/x86_64-unix/      Wine builtins, plus winemetal.so, cxcompatdb.so
lib/d3dmetal/              Apple D3DMetal (GPTK 4.0b1)   x86_64 only
lib/dxmt/                  DXMT                          x86_64 + i386
lib/dxvk/                  DXVK                          x86_64 + i386
lib/external/              libd3dshared.dylib, D3DMetal.framework
```

**A backend never overwrites a Wine builtin.** Each backend directory holds its
own `x86_64-windows` / `i386-windows` (and `x86_64-unix` where the backend has a
host-side library), so activating one is a single `prepend_dll_path()` call.
This mirrors how CrossOver itself ships (`lib/dxvk`, `lib64/apple_gptk`) and is
enforced by `scripts/install-renderers.sh`, which restores any builtin a
previous run shadowed.

Consequence: with `cxcompatdb` disabled the engine falls back to plain wined3d
rather than a half-D3DMetal, half-DXMT hybrid.

### Why `winemetal` lives in `lib/wine` too

`winemetal.dll` is DXMT's Metal bridge and has no Wine counterpart. CX26's
`ntdll` only loads a builtin PE if a fake DLL for it exists in
`C:\windows\system32`, and `wineboot -u` only generates those for modules it
finds in `lib/wine/<arch>`. A `winemetal.dll` that exists solely in `lib/dxmt`
never gets a fake DLL, so the loader fails early with `STATUS_DLL_NOT_FOUND`
and takes `dxgi.dll` and `d3d11.dll` down with it — no DLL override or registry
key can rescue it, because the rejection happens inside `ntdll` itself.

So `winemetal.dll` is copied into `lib/wine/<arch>` (as CrossOver does) and
`winemetal.so` into `lib/wine/x86_64-unix`, while `cxcompatdb` still swaps the
backend directory at runtime. Do not "clean this up" — DXMT stops loading.

## Selecting a backend

```bash
GAMMA_GRAPHICS_BACKEND=d3dmetal | dxmt | dxvk | wined3d | default
```

Also honoured, for compatibility with CrossOver/Sikarugir setups:
`D3DMETAL=1`, `DXMT=1`, `DXVK=1`, `CX_ACTIVE_GRAPHICS_BACKEND`, and the
`CYDER_`-prefixed spelling of every `GAMMA_` variable.

`scripts/interactive-setup.sh` prompts for the backend and writes it to
`~/Library/Application Support/<App>/app.env`, which the generated launcher
sources. Change it there and relaunch — no rebuild.

With `default` (or nothing set) the engine tries d3dmetal, then dxmt, then
wined3d, and uses the first that validates.

| Backend | API | Arch | Notes |
|---|---|---|---|
| `d3dmetal` | D3D11/12 via Metal | x86_64 | Default. Apple GPTK 4.0b1. No 32-bit payload exists, so 32-bit processes fall back. |
| `dxmt` | D3D11/10 via Metal | x86_64 + i386 | The only Metal backend available to 32-bit processes. **Currently crashes during startup — see below.** |
| `dxvk` | D3D11/10/9 via Vulkan | x86_64 + i386 | Needs a Vulkan-enabled engine — see below. Currently inert. |
| `wined3d` | OpenGL | both | Always available fallback. |

Activation is validated before it takes effect: the directory must contain a
real builtin PE for the running machine, plus `winemetal.dll` for dxmt and a
reachable `libd3dshared.dylib` for d3dmetal. A backend that fails validation
logs the reason to stderr (prefix `gamma-cxcompatdb:`) and falls back to
wined3d instead of failing the process.

## Known issue: DXMT crashes during startup

**Status: unresolved.** DXMT activates correctly but the game dies partway
through startup, during font/texture creation, with an
`invalid_parameter_handler` fatal error on a `concrt140` worker thread.
D3DMetal is unaffected and remains the default; use it for now. Full
investigation history (backtraces, ruled-out causes, next steps) is tracked
privately, not in this repo.

## DXVK: staged but not active

`lib/dxvk` is populated from a local CrossOver.app by
`scripts/install-renderers.sh` (real file copies — the engine tree never
references CrossOver.app at runtime). CrossOver's DXVK ships no `dxgi.dll`; it
pairs with Wine's builtin DXGI, and `validate_backend_directory()` exempts
dxvk/dxvk2 from the DXGI requirement accordingly.

It cannot activate yet: DXVK calls `vulkan-1.dll` → `winevulkan.so` →
MoltenVK, and the engine is currently configured `--without-vulkan`. Making it
live requires a full rebuild:

```bash
bash scripts/build-wine.sh --cx 26 --with-vulkan --vulkan-source crossover
```

which copies `libMoltenVK.dylib` out of CrossOver.app into `$GRAPHICS_INSTALL`
and bundles it into the engine. Until then `cxcompatdb` refuses the backend
(missing MoltenVK) and both `install-renderers.sh` and `interactive-setup.sh`
warn about it.

## CrossOver.app as an asset source

`scripts/env-x86_64.sh` auto-detects `~/Applications/CrossOver.app` or
`/Applications/CrossOver.app`; override with `CROSSOVER_APP`. Two things are
taken from it, always by copy:

- `lib64/libMoltenVK.dylib` → `--vulkan-source crossover`
- `lib/dxvk/` → the DXVK backend

D3DMetal is **not** taken from CrossOver — it comes from `sources/gptk4.0b1`.
