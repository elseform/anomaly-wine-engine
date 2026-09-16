# Graphics Backends

The engine exposes exactly two graphics backends: DXMT, and Apple D3DMetal
from GPTK. WineD3D still ships as one of Wine's builtins but is not
user-selectable and is never used as an automatic fallback — see
[Selection and fallback](#selection-and-fallback).

**GPTK is not bundled in this repo.** Apple's Game Porting Toolkit is
distributed under its own EULA (non-commercial, Apple-branded-device use
only) and is not redistributable here. D3DMetal is therefore an optional,
user-supplied backend: obtain GPTK yourself from Apple, then point
`install-renderers.sh` at your own payload — either `--apple-gptk <path>` or
the `GPTK_SRC` env var, pointing at a directory with the same
`d3dmetal/{wine,external}` shape GPTK itself ships (a `wine/x86_64-{windows,unix}`
tree and an `external/` directory containing `D3DMetal.framework` and
`libd3dshared.dylib`). If no GPTK payload is found, `install-renderers.sh`
skips D3DMetal staging and stages DXMT only — the build does not fail.

GPTK's version is a staging-time choice, not a runtime one: multiple local
GPTK payloads (e.g. different beta versions) can be compared by re-running
`install-renderers.sh --apple-gptk <path>` against each.

Selection happens at process start in `cxcompatdb.so`, built from
`runtime/cxcompatdb/cxcompatdb.c` and loaded by CrossOver's `ntdll`.

## Engine layout

```text
lib/wine/x86_64-windows/          Wine builtins, plus winemetal.dll
lib/wine/i386-windows/            Wine builtins, plus winemetal.dll
lib/wine/x86_64-unix/             Wine builtins, plus cxcompatdb.so
lib/dxmt/                         DXMT: x86_64, i386, and winemetal.so
lib64/apple_gptk/wine/            Apple D3DMetal GPTK (version staged via --apple-gptk)
lib64/apple_gptk/external/        libd3dshared.dylib and D3DMetal.framework
```

This follows CrossOver 26.3.0's renderer placement. Backend files never
replace Wine's Direct3D builtins. `winemetal.dll` is the narrow exception: it
also lives in `lib/wine/<arch>` because `wineboot` must discover it there and
create the corresponding fake DLL in the prefix. `winemetal.so` remains only
under `lib/dxmt/x86_64-unix`, matching CrossOver.

## Selection and fallback

There is no fallback: a validation failure terminates the process.

```bash
GAMMA_GRAPHICS_BACKEND=d3dmetal
GAMMA_GRAPHICS_BACKEND=dxmt
```

No other selector or compatibility alias is accepted. When the variable is
unset, DXMT is selected (GPTK/D3DMetal is optional and user-supplied — see
above — so it is never the unset-default). `cxcompatdb` derives the engine root from the
loaded `ntdll.so`, validates the selected backend for the current process
architecture, adds builtin load-order entries for modules actually present,
and prepends exactly one directory to Wine's DLL search path:

```text
d3dmetal  lib64/apple_gptk/wine
dxmt      lib/dxmt
```

If validation fails, `cxcompatdb` calls `_exit(1)` from its process
constructor instead of prepending anything — it does not leave Wine to
resolve its own builtins, and it does not try the other Metal backend. The
reason is logged to stderr with the `gamma-cxcompatdb:` prefix immediately
before the process exits.

| Backend | API | Architecture | Notes |
|---|---|---|---|
| `dxmt` | D3D11/10 via Metal | x86_64 + i386 | Default (via `interactive_setup.py`). Requires `winemetal.dll` and the host `winemetal.so`. |
| `d3dmetal` | D3D11/12 via Metal | x86_64 | GPTK only, user-supplied (not bundled, see above). A 32-bit process is terminated — no 32-bit payload exists, and there is no fallback. Use `dxmt` for 32-bit. |

GPTK's own `d3d10.dll`/`d3d10.so` ship as part of the payload — staging no
longer carves them out. They previously caused a confirmed savegame hang by
sharing D3DMetal state with D3D11, so `interactive_setup.py` still adds a
per-application `d3d10=builtin` DllOverride pinning a D3DMetal game to Wine's
own independent D3D10 implementation instead, regardless of which GPTK
payload is staged. Re-test the hang against a specific GPTK build by staging
it with `--apple-gptk` and comparing.

## DXMT status

DXMT selection and payload validation work, but the game has previously
crashed during startup on a `concrt140` worker thread. This remains a runtime
validation item; it does not change the two-backend packaging contract.

DLSS under DXMT (`DXMT_ENABLE_NVEXT=1`) is fixed and confirmed working as of
2026-09-14 — a DXMT-side NGX parameter-store type mismatch made
`NVSDK_NGX_D3D11_EvaluateFeature` fail on every call, so no DLSS upscale ever
actually ran regardless of in-game activation.
