/*
 * Minimal graphics-backend selector for GAMMA's CrossOver Wine build.
 *
 * CrossOver's ntdll.so loads this library at process start and exports the
 * two loader primitives used below. The only public selector is
 * GAMMA_GRAPHICS_BACKEND=d3dmetal|dxmt. Wine's built-in wined3d remains the
 * terminal fallback when the requested payload is unavailable.
 */

#include "config.h"

#include <dlfcn.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "windef.h"
#include "winternl.h"

extern void prepend_dll_path( const char *path );
extern void add_load_order_override( const WCHAR *entry );

#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))

static const char *const graphics_modules[] =
{
    "ddraw", "d3d8", "d3d9", "d3d10", "d3d10_1", "d3d10core",
    "d3d11", "d3d12", "dxgi", "winemetal", "nvapi64", "nvngx",
    "nvngx-on-metalfx", "atidxx64"
};

static void log_message( const char *level, const char *format, ... )
{
    va_list args;
    fprintf( stderr, "gamma-cxcompatdb:%s: ", level );
    va_start( args, format );
    vfprintf( stderr, format, args );
    va_end( args );
    fputc( '\n', stderr );
}

static uint16_t get_u16( const unsigned char *p )
{
    return p[0] | ((uint16_t)p[1] << 8);
}

static uint32_t get_u32( const unsigned char *p )
{
    return p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static int add_override( const char *module )
{
    WCHAR entry[64];
    size_t i, size = strlen( module );
    if (size + 3 > ARRAY_SIZE(entry)) return 0;
    for (i = 0; i < size; ++i) entry[i] = module[i];
    entry[size++] = '=';
    entry[size++] = 'b';
    entry[size] = 0;
    add_load_order_override( entry );
    return 1;
}

static int pe_is_builtin_for_machine( const char *path, uint16_t expected )
{
    unsigned char header[4096];
    uint32_t pe;
    ssize_t size;
    int fd = open( path, O_RDONLY );
    struct stat st;

    if (fd == -1) return 0;
    if (fstat( fd, &st ) == -1 || !S_ISREG( st.st_mode ) || st.st_size < 96)
    {
        close( fd );
        return 0;
    }
    size = read( fd, header, sizeof(header) );
    close( fd );
    if (size < 96 || header[0] != 'M' || header[1] != 'Z' ||
        memcmp( header + 64, "Wine builtin DLL", 16 )) return 0;
    pe = get_u32( header + 0x3c );
    return pe <= (uint32_t)size - 24 && !memcmp( header + pe, "PE\0\0", 4 ) &&
           get_u16( header + pe + 4 ) == expected;
}

static int canonical_directory( const char *input, char output[PATH_MAX] )
{
    struct stat st;
    return input && *input && realpath( input, output ) &&
           !stat( output, &st ) && S_ISDIR( st.st_mode ) &&
           !(st.st_mode & (S_IWGRP | S_IWOTH)) &&
           (st.st_uid == geteuid() || st.st_uid == 0);
}

static int engine_root_from_ntdll( char output[PATH_MAX] )
{
    static const char suffix[] = "/lib/wine/x86_64-unix/ntdll.so";
    Dl_info info;
    char resolved[PATH_MAX];
    size_t length, suffix_length = sizeof(suffix) - 1;

    if (!dladdr( (const void *)prepend_dll_path, &info ) || !info.dli_fname ||
        !realpath( info.dli_fname, resolved )) return 0;
    length = strlen( resolved );
    if (length <= suffix_length || strcmp( resolved + length - suffix_length, suffix )) return 0;
    resolved[length - suffix_length] = 0;
    if (strlen( resolved ) >= PATH_MAX) return 0;
    strcpy( output, resolved );
    return 1;
}

static const char *current_machine_directory( uint16_t *machine )
{
    TEB *teb = NtCurrentTeb();
    if (teb && teb->WowTebOffset)
    {
        *machine = 0x014c;
        return "i386-windows";
    }
    *machine = 0x8664;
    return "x86_64-windows";
}

static int validate_module( const char *backend_path, const char *machine_dir,
                            const char *module, uint16_t machine )
{
    char path[PATH_MAX];
    struct stat st;

    if (snprintf( path, sizeof(path), "%s/%s/%s.dll", backend_path,
                  machine_dir, module ) >= (int)sizeof(path)) return 0;
    if (lstat( path, &st ) == -1 || S_ISLNK( st.st_mode ) ||
        !pe_is_builtin_for_machine( path, machine ))
    {
        log_message( "error", "missing or invalid %s for %s: %s", module, machine_dir, path );
        return 0;
    }
    return 1;
}

static int readable_file( const char *format, const char *root, char output[PATH_MAX] )
{
    struct stat st;
    if (snprintf( output, PATH_MAX, format, root ) >= PATH_MAX) return 0;
    return !stat( output, &st ) && S_ISREG( st.st_mode ) && !access( output, R_OK );
}

static int activate_backend( const char *backend )
{
    char root[PATH_MAX], candidate[PATH_MAX], path[PATH_MAX];
    char support[PATH_MAX], framework[PATH_MAX];
    const char *machine_dir;
    uint16_t machine;
    unsigned int i;

    if (!engine_root_from_ntdll( root ))
    {
        log_message( "error", "cannot derive engine root from ntdll" );
        return 0;
    }

    if (!strcmp( backend, "d3dmetal" ))
        snprintf( candidate, sizeof(candidate), "%s/lib64/apple_gptk/wine", root );
    else
        snprintf( candidate, sizeof(candidate), "%s/lib/dxmt", root );

    if (!canonical_directory( candidate, path ))
    {
        log_message( "error", "backend directory unavailable: %s", candidate );
        return 0;
    }

    machine_dir = current_machine_directory( &machine );
    if (!validate_module( path, machine_dir, "d3d11", machine ) ||
        !validate_module( path, machine_dir, "dxgi", machine )) return 0;

    if (!strcmp( backend, "dxmt" ))
    {
        if (!validate_module( path, machine_dir, "winemetal", machine ) ||
            !readable_file( "%s/lib/dxmt/x86_64-unix/winemetal.so", root, support ))
        {
            log_message( "error", "DXMT host bridge unavailable below %s", root );
            return 0;
        }
    }
    else
    {
        if (!readable_file( "%s/lib64/apple_gptk/external/libd3dshared.dylib", root, support ))
        {
            log_message( "error", "D3DMetal libd3dshared.dylib unavailable below %s", root );
            return 0;
        }
        if (snprintf( framework, sizeof(framework),
                      "%s/lib64/apple_gptk/external/D3DMetal.framework", root ) >=
            (int)sizeof(framework) || access( framework, R_OK ))
        {
            log_message( "error", "D3DMetal.framework unavailable below %s", root );
            return 0;
        }
        setenv( "CX_APPLEGPTK_LIBD3DSHARED_PATH", support, 1 );
        setenv( "CX_D3DMETALPATH", framework, 1 );
    }

    for (i = 0; i < ARRAY_SIZE(graphics_modules); ++i)
    {
        char file[PATH_MAX];
        if (snprintf( file, sizeof(file), "%s/%s/%s.dll", path, machine_dir,
                      graphics_modules[i] ) < (int)sizeof(file) && !access( file, R_OK ))
            add_override( graphics_modules[i] );
    }

    {
        char *retained = strdup( path );
        if (!retained) return 0;
        prepend_dll_path( retained ); /* ntdll retains this pointer for process lifetime */
    }
    log_message( "info", "graphics backend=%s machine=%s path=%s", backend, machine_dir, path );
    return 1;
}

__attribute__((constructor))
static void compatdb_init(void)
{
    const char *backend = getenv( "GAMMA_GRAPHICS_BACKEND" );

    if (!backend || !*backend) backend = "d3dmetal";
    if (strcmp( backend, "d3dmetal" ) && strcmp( backend, "dxmt" ))
    {
        log_message( "error", "invalid GAMMA_GRAPHICS_BACKEND=%s; fallback=wined3d", backend );
        return;
    }
    if (!activate_backend( backend ))
        log_message( "warning", "graphics backend=%s rejected; fallback=wined3d", backend );
}
