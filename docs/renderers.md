# Graphics Backends

The engine exposes exactly two graphics backends: Apple D3DMetal from GPTK
4.0b2 and DXMT. WineD3D still ships as one of Wine's builtins but is not
user-selectable and is never used as an automatic fallback — see
[Selection and fallback](#selection-and-fallback).

Selection happens at process start in `cxcompatdb.so`, built from
`runtime/cxcompatdb/cxcompatdb.c` and loaded by CrossOver's `ntdll`.

## Engine layout

```text
lib/wine/x86_64-windows/          Wine builtins, plus winemetal.dll
lib/wine/i386-windows/            Wine builtins, plus winemetal.dll
lib/wine/x86_64-unix/             Wine builtins, plus cxcompatdb.so
lib/dxmt/                         DXMT: x86_64, i386, and winemetal.so
lib64/apple_gptk/wine/            Apple D3DMetal GPTK 4.0b2
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
unset, D3DMetal is selected. `cxcompatdb` derives the engine root from the
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
| `d3dmetal` | D3D11/12 via Metal | x86_64 | Default; GPTK 4.0b2 only. A 32-bit process is terminated — no 32-bit payload exists, and there is no fallback. Use `dxmt` for 32-bit. |
| `dxmt` | D3D11/10 via Metal | x86_64 + i386 | Requires `winemetal.dll` and the host `winemetal.so`. |

GPTK's `d3d10.dll` and `d3d10.so` are deliberately excluded. They caused a
confirmed savegame hang by sharing D3DMetal state with D3D11. Interactive setup
adds a per-application `d3d10=builtin` override for a D3DMetal game prefix.

## DXMT status

DXMT selection and payload validation work, but the game has previously
crashed during startup on a `concrt140` worker thread. This remains a runtime
validation item; it does not change the two-backend packaging contract.
