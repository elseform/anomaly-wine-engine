/*
 * d3dx11_43 safety shim.
 *
 * Null-checks the texture/resource pointers GAMMA's savegame-thumbnail path
 * actually passes before forwarding to the real DLL, so a texture that
 * D3DMetal's CreateTexture2D silently failed to populate (returns S_OK with
 * a null out-pointer) produces a graceful HRESULT failure instead of a page
 * fault. Everything else is untouched — see def/d3dx11_43-x86_64.def and
 * def/d3dx11_43-i386.def for the plain forwarders.
 *
 * Deliberately avoids the DirectX SDK headers: only pointer/integer types
 * are needed to null-check and forward, so there is no dependency on
 * d3d11.h/d3dx11.h being present in the cross toolchain's sysroot.
 */

#include <windows.h>

#if defined(_WIN64)
#define D3DX11_CALL
#else
#define D3DX11_CALL __stdcall
#endif

typedef LONG HRESULT_T;
#define E_POINTER_T   ((HRESULT_T)0x80004003L)

static HMODULE g_real = NULL;

static HMODULE real_dll(void)
{
    if (!g_real)
        g_real = LoadLibraryA("d3dx11_43_orig.dll");
    return g_real;
}

typedef HRESULT_T (D3DX11_CALL *LoadTextureFromTexture_t)(void *context, void *src_texture, void *info, void *dst_texture);
typedef HRESULT_T (D3DX11_CALL *SaveTextureToMemory_t)(void *context, void *texture, LONG format, void *buffer_out, LONG flags);
typedef HRESULT_T (D3DX11_CALL *SaveTextureToFileA_t)(void *context, void *texture, LONG format, const char *filename);
typedef HRESULT_T (D3DX11_CALL *SaveTextureToFileW_t)(void *context, void *texture, LONG format, const WCHAR *filename);

__declspec(dllexport) HRESULT_T D3DX11_CALL D3DX11LoadTextureFromTexture(
    void *context, void *src_texture, void *info, void *dst_texture)
{
    LoadTextureFromTexture_t fn;
    HMODULE dll = real_dll();

    if (!src_texture || !dst_texture)
        return E_POINTER_T;
    if (!dll)
        return E_POINTER_T;

    fn = (LoadTextureFromTexture_t)(void *)GetProcAddress(dll, "D3DX11LoadTextureFromTexture");
    if (!fn)
        return E_POINTER_T;
    return fn(context, src_texture, info, dst_texture);
}

__declspec(dllexport) HRESULT_T D3DX11_CALL D3DX11SaveTextureToMemory(
    void *context, void *texture, LONG format, void *buffer_out, LONG flags)
{
    SaveTextureToMemory_t fn;
    HMODULE dll = real_dll();

    if (!texture)
        return E_POINTER_T;
    if (!dll)
        return E_POINTER_T;

    fn = (SaveTextureToMemory_t)(void *)GetProcAddress(dll, "D3DX11SaveTextureToMemory");
    if (!fn)
        return E_POINTER_T;
    return fn(context, texture, format, buffer_out, flags);
}

__declspec(dllexport) HRESULT_T D3DX11_CALL D3DX11SaveTextureToFileA(
    void *context, void *texture, LONG format, const char *filename)
{
    SaveTextureToFileA_t fn;
    HMODULE dll = real_dll();

    if (!texture)
        return E_POINTER_T;
    if (!dll)
        return E_POINTER_T;

    fn = (SaveTextureToFileA_t)(void *)GetProcAddress(dll, "D3DX11SaveTextureToFileA");
    if (!fn)
        return E_POINTER_T;
    return fn(context, texture, format, filename);
}

__declspec(dllexport) HRESULT_T D3DX11_CALL D3DX11SaveTextureToFileW(
    void *context, void *texture, LONG format, const WCHAR *filename)
{
    SaveTextureToFileW_t fn;
    HMODULE dll = real_dll();

    if (!texture)
        return E_POINTER_T;
    if (!dll)
        return E_POINTER_T;

    fn = (SaveTextureToFileW_t)(void *)GetProcAddress(dll, "D3DX11SaveTextureToFileW");
    if (!fn)
        return E_POINTER_T;
    return fn(context, texture, format, filename);
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved)
{
    (void)inst; (void)reserved;
    if (reason == DLL_PROCESS_DETACH && g_real)
        FreeLibrary(g_real);
    return TRUE;
}
