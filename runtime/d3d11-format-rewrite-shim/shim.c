/*
 * d3d11 format-rewrite shim, targeting the D3DMetal-supplied d3d11.dll.
 *
 * GAMMA/Anomaly's savegame-thumbnail path (Layers/xrRender/r__screenshot.cpp,
 * SM_FOR_GAMESAVE) creates a 128x128 DXGI_FORMAT_BC1_UNORM texture, then
 * uses D3DX11LoadTextureFromTexture to compress the render target into it
 * on the fly. This crashes deep inside d3dx11_43 (page fault, null COM
 * pointer, identical across GPTK 40b1/40b2 and two different Wine trees —
 * see docs/d3dmetal-savegame-crash.md). Root cause is presumed to be
 * D3DMetal's CreateTexture2D returning S_OK with a malformed/half-wired
 * texture object for this specific compressed-format + tiny-size +
 * shader-resource-only creation pattern — a bug inside GPTK's closed-source
 * D3DMetal.framework, not patchable directly.
 *
 * This shim sidesteps the bug instead of chasing it: intercepts
 * D3D11CreateDevice / D3D11CreateDeviceAndSwapChain, and after the real
 * device is created, patches its vtable slot for CreateTexture2D (a
 * standard, stable, publicly-documented COM ABI position — ID3D11Device
 * inherits IUnknown directly, so CreateTexture2D is vtable index 5:
 * QueryInterface=0, AddRef=1, Release=2, CreateBuffer=3, CreateTexture1D=4,
 * CreateTexture2D=5 — confirmed against Wine's own d3d11.idl). The
 * installed trampoline rewrites DXGI_FORMAT_BC1_UNORM to
 * DXGI_FORMAT_R8G8B8A8_UNORM only for creation requests matching the exact
 * signature GAMESAVE_SIZE-thumbnail creation uses (128x128, 1 mip, 1 array
 * slice, D3D11_USAGE_DEFAULT, BindFlags=D3D11_BIND_SHADER_RESOURCE only) —
 * every other texture creation passes through untouched. An uncompressed
 * 128x128 RGBA8 texture is ~64KB vs BC1's ~8KB — trivial for a savegame
 * thumbnail — and takes a well-supported, ordinary D3D11 code path instead
 * of GPTK's apparently-broken on-the-fly BC1 compression.
 *
 * The vtable patch targets the *shared* vtable array all instances of
 * D3DMetal's device class point at (standard C++ ABI: one static vtable per
 * class, each instance stores only a pointer to it) — patched once, on the
 * first device created, using VirtualProtect to make that one pointer slot
 * temporarily writable. Every subsequent device (if any) already shares the
 * patched array.
 */

#include <windows.h>
#include <stdio.h>
#include <stdarg.h>

static void dbg( const char *fmt, ... )
{
    FILE *f = fopen( "Z:\\tmp\\d3d11_shim_debug.txt", "a" );
    va_list ap;
    if (!f) return;
    va_start( ap, fmt );
    vfprintf( f, fmt, ap );
    va_end( ap );
    fclose( f );
}

static HMODULE g_real = NULL;

static HMODULE real_dll(void)
{
    if (!g_real)
        g_real = LoadLibraryA("d3d11_orig.dll");
    return g_real;
}

/* ---- minimal D3D11_TEXTURE2D_DESC layout, no DirectX headers needed ---- */
typedef struct
{
    UINT Width;
    UINT Height;
    UINT MipLevels;
    UINT ArraySize;
    DWORD Format;
    UINT SampleCount;
    UINT SampleQuality;
    DWORD Usage;
    UINT BindFlags;
    UINT CPUAccessFlags;
    UINT MiscFlags;
} TEX2D_DESC;

#define DXGI_FORMAT_R8G8B8A8_UNORM 28
#define DXGI_FORMAT_BC1_UNORM     71
#define D3D11_USAGE_DEFAULT        0
#define D3D11_BIND_SHADER_RESOURCE 8
#define GAMESAVE_SIZE             128

typedef HRESULT (WINAPI *CreateTexture2D_t)(void *this_, const TEX2D_DESC *desc,
                                             const void *initial_data, void **out_texture);
static CreateTexture2D_t g_real_CreateTexture2D;

static int matches_gamesave_thumbnail( const TEX2D_DESC *d )
{
    return d
        && d->Width == GAMESAVE_SIZE
        && d->Height == GAMESAVE_SIZE
        && d->MipLevels == 1
        && d->ArraySize == 1
        && d->Format == DXGI_FORMAT_BC1_UNORM
        && d->SampleCount == 1
        && d->Usage == D3D11_USAGE_DEFAULT
        && d->BindFlags == D3D11_BIND_SHADER_RESOURCE;
}

static HRESULT WINAPI hook_CreateTexture2D( void *this_, const TEX2D_DESC *desc,
                                             const void *initial_data, void **out_texture )
{
    TEX2D_DESC rewritten;

    if (matches_gamesave_thumbnail( desc ))
    {
        rewritten = *desc;
        rewritten.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        desc = &rewritten;
    }
    return g_real_CreateTexture2D( this_, desc, initial_data, out_texture );
}

static volatile LONG g_vtable_patched = 0;

static void patch_device_vtable( void *device )
{
    void ***self;
    void **vtbl;
    DWORD old_protect;

    if (!device) return;
    if (InterlockedCompareExchange( &g_vtable_patched, 1, 0 ) != 0) return; /* already patched */

    self = (void ***)device;
    vtbl = *self;

    if (!VirtualProtect( &vtbl[5], sizeof(void *), PAGE_EXECUTE_READWRITE, &old_protect ))
        return;

    g_real_CreateTexture2D = (CreateTexture2D_t)vtbl[5];
    vtbl[5] = (void *)hook_CreateTexture2D;

    VirtualProtect( &vtbl[5], sizeof(void *), old_protect, &old_protect );
}

/* ---- entry points: forward to the real DLL, then patch the returned device ---- */

typedef HRESULT (WINAPI *D3D11CreateDevice_t)(
    void *adapter, int driver_type, HMODULE software, UINT flags,
    const void *feature_levels, UINT num_feature_levels, UINT sdk_version,
    void **out_device, void *out_feature_level, void **out_context );

static D3D11CreateDevice_t g_fn_CreateDevice;

__declspec(dllexport) HRESULT WINAPI D3D11CreateDevice(
    void *adapter, int driver_type, HMODULE software, UINT flags,
    const void *feature_levels, UINT num_feature_levels, UINT sdk_version,
    void **out_device, void *out_feature_level, void **out_context )
{
    HRESULT hr;

    if (!g_fn_CreateDevice)
    {
        HMODULE dll = real_dll();
        if (!dll) return E_FAIL;
        g_fn_CreateDevice = (D3D11CreateDevice_t)(void *)GetProcAddress( dll, "D3D11CreateDevice" );
        if (!g_fn_CreateDevice) return E_FAIL;
    }

    hr = g_fn_CreateDevice( adapter, driver_type, software, flags, feature_levels, num_feature_levels,
              sdk_version, out_device, out_feature_level, out_context );
    if (SUCCEEDED(hr) && out_device && *out_device)
        patch_device_vtable( *out_device );
    return hr;
}

typedef HRESULT (WINAPI *D3D11CreateDeviceAndSwapChain_t)(
    void *adapter, int driver_type, HMODULE software, UINT flags,
    const void *feature_levels, UINT num_feature_levels, UINT sdk_version,
    const void *swap_chain_desc, void **out_swap_chain,
    void **out_device, void *out_feature_level, void **out_context );

static D3D11CreateDeviceAndSwapChain_t g_fn_CreateDeviceAndSwapChain;

__declspec(dllexport) HRESULT WINAPI D3D11CreateDeviceAndSwapChain(
    void *adapter, int driver_type, HMODULE software, UINT flags,
    const void *feature_levels, UINT num_feature_levels, UINT sdk_version,
    const void *swap_chain_desc, void **out_swap_chain,
    void **out_device, void *out_feature_level, void **out_context )
{
    HRESULT hr;

    dbg( "AndSwapChain: enter driver_type=%d flags=%u\n", driver_type, flags );

    if (!g_fn_CreateDeviceAndSwapChain)
    {
        HMODULE dll = real_dll();
        dbg( "AndSwapChain: LoadLibrary(d3d11_orig.dll) -> %p\n", (void*)dll );
        if (!dll) return E_FAIL;
        g_fn_CreateDeviceAndSwapChain =
            (D3D11CreateDeviceAndSwapChain_t)(void *)GetProcAddress( dll, "D3D11CreateDeviceAndSwapChain" );
        dbg( "AndSwapChain: GetProcAddress -> %p\n", (void*)g_fn_CreateDeviceAndSwapChain );
        if (!g_fn_CreateDeviceAndSwapChain) return E_FAIL;
    }

    hr = g_fn_CreateDeviceAndSwapChain( adapter, driver_type, software, flags, feature_levels,
              num_feature_levels, sdk_version, swap_chain_desc, out_swap_chain, out_device,
              out_feature_level, out_context );
    dbg( "AndSwapChain: real call returned hr=0x%08lx out_device=%p\n", (long)hr,
         out_device ? *out_device : NULL );
    if (SUCCEEDED(hr) && out_device && *out_device)
        patch_device_vtable( *out_device );
    return hr;
}

BOOL WINAPI DllMain( HINSTANCE inst, DWORD reason, LPVOID reserved )
{
    (void)inst; (void)reserved;
    if (reason == DLL_PROCESS_DETACH && g_real)
        FreeLibrary( g_real );
    return TRUE;
}
