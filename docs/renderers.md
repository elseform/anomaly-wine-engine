# Graphics Backend

The engine has one graphics backend: DXMT. WineD3D still ships as one of
Wine's builtins but is not user-selectable and is never used as an automatic
fallback — see [Selection and fallback](#selection-and-fallback). D3DMetal
(Apple's Game Porting Toolkit) and DXVK are not supported.

DXMT comes from a release of [`elseform/dxmt-wine`](https://github.com/elseform/dxmt-wine),
downloaded and verified at pack time (see
[building.md](building.md#the-dxmt-payload)). Selection happens at process
start in `cxcompatdb.so`, built from `runtime/cxcompatdb/cxcompatdb.c` and
loaded by CrossOver's `ntdll`.

## Selection and fallback

There is no fallback: a validation failure terminates the process.
`ANOMALY_GRAPHICS_BACKEND` may be unset or `dxmt`; any other value (including
the former `d3dmetal`) terminates the process. The archive layout and the
selection and validation steps `cxcompatdb` performs are in
[Architecture](architecture.md#backend-selection-at-runtime); the reason for a
failed validation is logged to stderr with the `anomaly-cxcompatdb:` prefix
immediately before the process exits.

| Backend | API | Architecture | Notes |
|---|---|---|---|
| `dxmt` | D3D11/10 via Metal | x86_64 | Requires `winemetal.dll` and the host `winemetal.so`. A 32-bit process is terminated. |

## DXMT status

DXMT selection and payload validation work, but the game has previously
crashed during startup on a `concrt140` worker thread. This remains a runtime
validation item. DLSS under DXMT is enabled with `DXMT_ENABLE_NVEXT=1`
([Getting Started](getting-started.md#3-changing-settings)); the fixes behind
it are listed in the DXMT [changelog](https://github.com/elseform/dxmt-wine/blob/release/CHANGELOG.md).
