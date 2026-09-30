# Graphics Backend

The engine has one graphics backend: DXMT. WineD3D still ships as one of
Wine's builtins but is not user-selectable and is never used as an automatic
fallback — see [Selection and fallback](#selection-and-fallback). D3DMetal
(Apple's Game Porting Toolkit) and DXVK are not supported.

DXMT comes from a release of [`elseform/dxmt`](https://github.com/elseform/dxmt),
downloaded and verified at pack time (see
[building.md](building.md#the-dxmt-payload)). Selection happens at process
start in `cxcompatdb.so`, built from `runtime/cxcompatdb/cxcompatdb.c` and
loaded by CrossOver's `ntdll`.

## Engine layout

```text
lib/wine/x86_64-windows/          Wine builtins, plus a copy of winemetal.dll
lib/wine/i386-windows/            Wine's 32-bit builtins
lib/wine/x86_64-unix/             Wine builtins, plus cxcompatdb.so
lib/dxmt/x86_64-windows/          DXMT (x86_64 only)
lib/dxmt/x86_64-unix/             winemetal.so, DXMT's host bridge
```

This follows CrossOver 26.3.0's renderer placement. Backend files never
replace Wine's Direct3D builtins. `winemetal.dll` is the narrow exception: a
copy also lives in `lib/wine/x86_64-windows` because `wineboot` must discover it
there and create the corresponding fake DLL in the prefix. The copy in
`lib/dxmt` is the one that loads, because `cxcompatdb` puts `lib/dxmt` first on
the DLL search path. `winemetal.so` remains only
under `lib/dxmt/x86_64-unix`, matching CrossOver.

## Selection and fallback

There is no fallback: a validation failure terminates the process.
`ANOMALY_GRAPHICS_BACKEND` may be unset or `dxmt`; any other value (including
the former `d3dmetal`) terminates the process. `cxcompatdb` derives the engine
root from the loaded `ntdll.so`, validates DXMT for the current process
architecture (`d3d11`, `dxgi` and `winemetal` in `lib/dxmt/<arch>-windows/`,
plus `lib/dxmt/x86_64-unix/winemetal.so`), adds builtin load-order entries for
the modules actually present, and prepends `lib/dxmt` to Wine's DLL search
path.

If validation fails, `cxcompatdb` calls `_exit(1)` from its process
constructor instead of prepending anything — it does not leave Wine to
resolve its own builtins. The reason is logged to stderr with the
`anomaly-cxcompatdb:` prefix immediately before the process exits.

| Backend | API | Architecture | Notes |
|---|---|---|---|
| `dxmt` | D3D11/10 via Metal | x86_64 | Requires `winemetal.dll` and the host `winemetal.so`. A 32-bit process is terminated. |

## DXMT status

DXMT selection and payload validation work, but the game has previously
crashed during startup on a `concrt140` worker thread. This remains a runtime
validation item.

DLSS under DXMT (`DXMT_ENABLE_NVEXT=1`) is fixed and confirmed working as of
2026-09-14 — a DXMT-side NGX parameter-store type mismatch made
`NVSDK_NGX_D3D11_EvaluateFeature` fail on every call, so no DLSS upscale ever
actually ran regardless of in-game activation.
