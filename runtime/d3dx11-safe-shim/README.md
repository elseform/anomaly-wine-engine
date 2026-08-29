# d3dx11-safe-shim

Thin proxy for `d3dx11_43.dll` that null-checks the resource/texture pointers
before forwarding to the real (Microsoft) implementation, and forwards every
other export unmodified via PE forwarder RVAs.

## Why

GAMMA/Anomaly's savegame-thumbnail path (`Layers/xrRender/r__screenshot.cpp`,
`SM_FOR_GAMESAVE` case) creates a `DXGI_FORMAT_BC1_UNORM` texture via
`HW.pDevice->CreateTexture2D(&desc, NULL, &pSrcSmallTexture)`, wrapped only in
`CHK_DX` (checks the `HRESULT`, not whether the output pointer actually came
back non-null). Under D3DMetal specifically, this call has been observed to
return `S_OK` while leaving `pSrcSmallTexture` null — confirmed via a crash
signature that is identical across GPTK 40b1/40b2, with and without the
`-dxgi-old` engine flag, and regardless of `d3dx11_43`'s DllOverride mode: a
page fault reading address `0x0` inside `d3dx11_43`, both `rax` and `rcx` zero
at the fault, three frames deep inside `D3DX11LoadTextureFromTexture` /
`D3DX11SaveTextureToMemory` — consistent with those functions dereferencing a
null COM object passed in as the destination/source texture.

`D3DMetal.framework` is closed-source Apple code — not patchable. This shim
fixes the *symptom* at the Wine layer instead: null-check the texture
pointers GAMMA's savegame path actually passes, and return a `HRESULT`
failure instead of crashing. The game already checks `if (hr == D3D_OK)`
before treating the save as having written thumbnail data, so a graceful
failure here just means the save has no thumbnail — not a crash.

## What's intercepted vs. forwarded

- `D3DX11LoadTextureFromTexture`: null-checks `src_texture` and
  `dst_texture` (3rd/4th params) before forwarding.
- `D3DX11SaveTextureToMemory`: null-checks `texture` (2nd param) before
  forwarding.
- `D3DX11SaveTextureToFileA`/`W`: same null-check on `texture`, for symmetry
  (GAMMA doesn't call these directly today, but nothing else should crash
  the same way if it starts to).
- Every other export (`D3DX11CreateTextureFromMemory`,
  `D3DX11GetImageInfoFromMemory`, `D3DX11CompileFromFileA`, etc.) is a plain
  PE forwarder to the renamed real DLL — zero behavior change.

## Install

The real DLL must be renamed to `d3dx11_43_orig.dll` alongside this shim
(both `system32` and `syswow64`/i386 windows dirs), since the forwarders and
the intercepted functions' fallback path both `LoadLibraryA`/forward to that
exact name.

```bash
bash build.sh                          # produces build/{x86_64,i386}/d3dx11_43.dll
bash install.sh "$WINEPREFIX"          # renames real DLLs, drops shim in place
```
