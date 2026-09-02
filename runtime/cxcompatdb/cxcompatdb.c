/*
 * Cyder's open cxcompatdb replacement for CrossOver Wine.
 *
 * CrossOver's unmodified ntdll.so loads this file and exports the two loader
 * primitives below.  Policy stays here; ntdll remains an engine mechanism.
 */

#include "config.h"

#include <errno.h>
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

#define CDB_HEADER_SIZE 40
#define CDB_MAX_SIZE (4 * 1024 * 1024)
#define CDB_REQUIRED 1
#define MAX_ITEMS 64
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))

enum record_type
{
    RULE_BEGIN = 0x0001, RULE_END = 0x0002,
    RULE_ID = 0x0010, PRIORITY = 0x0011, ENABLED = 0x0012,
    MATCH_PATH_SUFFIX = 0x0020, MATCH_FORBIDDEN_ARG = 0x0021,
    ACTION_APPEND_ARG = 0x0030, ACTION_DLL_OVERRIDE = 0x0031,
    ACTION_SET_ENV = 0x0032, ACTION_UNSET_ENV = 0x0033,
    ACTION_GRAPHICS_BACKEND = 0x0034, ACTION_REPLACE_EXECUTABLE = 0x0035,
    ACTION_WINED3D_RENDERER = 0x0036
};

struct slice { const unsigned char *data; uint32_t size; };

struct rule
{
    struct slice paths[MAX_ITEMS], forbidden[MAX_ITEMS], args[MAX_ITEMS], dlls[MAX_ITEMS];
    struct slice graphics;
    unsigned int path_count, forbidden_count, arg_count, dll_count;
    int32_t priority;
    int have_id, have_priority, have_enabled, have_graphics, enabled, invalid;
};

struct database
{
    unsigned char *data;
    size_t size;
    uint32_t records, rules;
};

static const char *const graphics_modules[] =
{
    "ddraw", "d3d8", "d3d9", "d3d10", "d3d10_1", "d3d10core",
    "d3d11", "d3d12", "dxgi", "winemetal", "nvapi64", "nvngx"
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

static const char *get_gamma_env( const char *name )
{
    static char buf[128];
    const char *val;
    snprintf( buf, sizeof(buf), "GAMMA_%s", name );
    if ((val = getenv( buf )) && *val) return val;
    snprintf( buf, sizeof(buf), "CYDER_%s", name );
    if ((val = getenv( buf )) && *val) return val;
    return NULL;
}

static uint16_t get_u16( const unsigned char *p )
{
    return p[0] | ((uint16_t)p[1] << 8);
}

static uint32_t get_u32( const unsigned char *p )
{
    return p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint64_t get_u64( const unsigned char *p )
{
    return get_u32( p ) | ((uint64_t)get_u32( p + 4 ) << 32);
}

static int read_fully( int fd, void *buffer, size_t size )
{
    unsigned char *p = buffer;
    while (size)
    {
        ssize_t count = read( fd, p, size );
        if (count > 0) p += count, size -= count;
        else if (!count || errno != EINTR) return 0;
    }
    return 1;
}

static int load_database( const char *path, struct database *db )
{
    static const unsigned char magic[8] = {'C','Y','D','R','C','D','B',0};
    struct stat st;
    int fd = -1;

    memset( db, 0, sizeof(*db) );
    if (!path || !*path || (fd = open( path, O_RDONLY )) == -1) return 0;
    if (fstat( fd, &st ) == -1 || !S_ISREG( st.st_mode ) ||
        st.st_size < CDB_HEADER_SIZE || st.st_size > CDB_MAX_SIZE ||
        !(db->data = malloc( st.st_size )) || !read_fully( fd, db->data, st.st_size ))
        goto failed;
    close( fd );
    db->size = st.st_size;
    if (memcmp( db->data, magic, sizeof(magic) ) || get_u16( db->data + 8 ) != 1 ||
        get_u16( db->data + 10 ) != CDB_HEADER_SIZE || get_u32( db->data + 12 ) ||
        get_u64( db->data + 16 ) != db->size || get_u32( db->data + 32 ) != CDB_HEADER_SIZE ||
        get_u32( db->data + 36 )) goto invalid;
    db->records = get_u32( db->data + 24 );
    db->rules = get_u32( db->data + 28 );
    if (db->records > 65536 || db->rules > 4096) goto invalid;
    return 1;

failed:
    if (fd != -1) close( fd );
invalid:
    free( db->data );
    memset( db, 0, sizeof(*db) );
    return 0;
}

static int validate_database( const struct database *db )
{
    size_t offset = CDB_HEADER_SIZE;
    uint32_t i, rules = 0;
    int in_rule = 0;
    for (i = 0; i < db->records; ++i)
    {
        uint16_t type;
        uint32_t size;
        if (offset > db->size || db->size - offset < 8) return 0;
        type = get_u16( db->data + offset );
        size = get_u32( db->data + offset + 4 );
        offset += 8;
        if (size > 65536 || size > db->size - offset) return 0;
        if (type == RULE_BEGIN)
        {
            if (in_rule || size) return 0;
            in_rule = 1;
        }
        else if (type == RULE_END)
        {
            if (!in_rule || size) return 0;
            in_rule = 0;
            ++rules;
        }
        else if (!in_rule) return 0;
        offset += size;
    }
    return !in_rule && offset == db->size && rules == db->rules;
}

static int valid_ascii( const struct slice *s )
{
    uint32_t i;
    if (!s->size || s->size > 4096) return 0;
    for (i = 0; i < s->size; ++i)
        if (!s->data[i] || s->data[i] >= 0x80) return 0;
    return 1;
}

static int slice_equals( const struct slice *s, const char *value )
{
    size_t size = strlen( value );
    return s->size == size && !memcmp( s->data, value, size );
}

static int valid_backend( const struct slice *s )
{
    /* gptk40b1/gptk40b2 are first-class GAMMA_GRAPHICS_BACKEND values picking
     * a specific D3DMetal GPTK beta directly (lib/gptk40b1, lib/gptk40b2,
     * same flat shape as lib/d3dmetal) — see docs/d3dmetal-savegame-crash.md
     * in gamma-wine-engine. */
    return slice_equals( s, "default" ) || slice_equals( s, "wined3d" ) ||
           slice_equals( s, "dxvk" ) || slice_equals( s, "dxvk2" ) ||
           slice_equals( s, "dxmt" ) || slice_equals( s, "d3dmetal" ) ||
           slice_equals( s, "gptk40b1" ) || slice_equals( s, "gptk40b2" );
}

static int wide_ascii_nocase( WCHAR a, unsigned char b )
{
    if (a == '/') a = '\\';
    if (b == '/') b = '\\';
    if (a >= 'A' && a <= 'Z') a += 'a' - 'A';
    if (b >= 'A' && b <= 'Z') b += 'a' - 'A';
    return a == b;
}

static int path_matches( const UNICODE_STRING *path, const struct slice *suffix )
{
    size_t path_len = path->Length / sizeof(WCHAR), i;
    if (!valid_ascii( suffix ) || suffix->size > path_len || suffix->data[0] != '\\') return 0;
    for (i = 0; i < suffix->size; ++i)
        if (!wide_ascii_nocase( path->Buffer[path_len - suffix->size + i], suffix->data[i] )) return 0;
    return 1;
}

static const WCHAR *next_argument( const WCHAR *src, const WCHAR *end,
                                   WCHAR *buffer, size_t *length )
{
    WCHAR *dst = buffer;
    int quoted = 0;
    while (src < end && (*src == ' ' || *src == '\t')) ++src;
    while (src < end && (quoted || (*src != ' ' && *src != '\t')))
    {
        size_t slashes = 0, i;
        while (src < end && *src == '\\') ++slashes, ++src;
        if (src < end && *src == '"')
        {
            for (i = 0; i < slashes / 2; ++i) *dst++ = '\\';
            if (slashes & 1) *dst++ = '"', ++src;
            else
            {
                ++src;
                if (quoted && src < end && *src == '"') *dst++ = '"', ++src;
                else quoted = !quoted;
            }
        }
        else
        {
            while (slashes--) *dst++ = '\\';
            if (src < end && (quoted || (*src != ' ' && *src != '\t'))) *dst++ = *src++;
        }
    }
    *length = dst - buffer;
    while (src < end && (*src == ' ' || *src == '\t')) ++src;
    return src;
}

static size_t option_key_length_w( const WCHAR *arg, size_t size )
{
    size_t i;
    if (!size || (arg[0] != '-' && arg[0] != '/')) return size;
    for (i = 1; i < size; ++i) if (arg[i] == '=') return i;
    return size;
}

static size_t option_key_length_a( const struct slice *arg )
{
    size_t i;
    if (!arg->size || (arg->data[0] != '-' && arg->data[0] != '/')) return arg->size;
    for (i = 1; i < arg->size; ++i) if (arg->data[i] == '=') return i;
    return arg->size;
}

static int command_has_argument( const UNICODE_STRING *line, const struct slice *wanted,
                                 int option_key )
{
    const WCHAR *src = line->Buffer, *end = src + line->Length / sizeof(WCHAR);
    WCHAR *arg;
    size_t wanted_size = option_key ? option_key_length_a( wanted ) : wanted->size;
    int wanted_option = wanted->size && (wanted->data[0] == '-' || wanted->data[0] == '/');
    if (!valid_ascii( wanted ) || !(arg = malloc( (end - src + 1) * sizeof(*arg) ))) return 0;
    while (src < end)
    {
        size_t size, compare, i;
        const WCHAR *next = next_argument( src, end, arg, &size );
        compare = option_key ? option_key_length_w( arg, size ) : size;
        if (compare == wanted_size)
        {
            int equal = 1;
            for (i = 0; i < compare; ++i)
            {
                WCHAR a = arg[i];
                unsigned char b = wanted->data[i];
                if (wanted_option && option_key)
                {
                    if (a >= 'A' && a <= 'Z') a += 'a' - 'A';
                    if (b >= 'A' && b <= 'Z') b += 'a' - 'A';
                }
                if (a != b) { equal = 0; break; }
            }
            if (equal) { free( arg ); return 1; }
        }
        if (next <= src) break;
        src = next;
    }
    free( arg );
    return 0;
}

static size_t encoded_argument_size( const struct slice *arg, int *quote )
{
    size_t i, size = arg->size;
    *quote = !arg->size;
    for (i = 0; i < arg->size; ++i)
        if (arg->data[i] == ' ' || arg->data[i] == '\t' || arg->data[i] == '"') *quote = 1;
    if (!*quote) return size;
    size = 2;
    for (i = 0; i < arg->size; ++i)
        size += arg->data[i] == '"' ? 2 : 1;
    return size;
}

static int append_argument( RTL_USER_PROCESS_PARAMETERS *params, const struct slice *arg )
{
    size_t old_size = params->CommandLine.Length / sizeof(WCHAR), i, total;
    WCHAR *buffer, *dst;
    int quote;
    if (!valid_ascii( arg ) || command_has_argument( &params->CommandLine, arg, 1 )) return 1;
    total = old_size + !!old_size + encoded_argument_size( arg, &quote );
    if (total + 1 > USHRT_MAX / sizeof(WCHAR) || !(buffer = malloc( (total + 1) * sizeof(*buffer) )))
        return 0;
    memcpy( buffer, params->CommandLine.Buffer, old_size * sizeof(*buffer) );
    dst = buffer + old_size;
    if (old_size) *dst++ = ' ';
    if (quote) *dst++ = '"';
    for (i = 0; i < arg->size; ++i)
    {
        if (quote && arg->data[i] == '"') *dst++ = '\\';
        *dst++ = arg->data[i];
    }
    if (quote) *dst++ = '"';
    *dst = 0;
    params->CommandLine.Buffer = buffer; /* process-lifetime allocation */
    params->CommandLine.Length = total * sizeof(WCHAR);
    params->CommandLine.MaximumLength = (total + 1) * sizeof(WCHAR);
    log_message( "info", "appended current-process argument %.*s", (int)arg->size, arg->data );
    return 1;
}

static int add_override_slice( const struct slice *value )
{
    WCHAR *entry;
    uint32_t i;
    if (!valid_ascii( value ) || !(entry = calloc( value->size + 1, sizeof(*entry) ))) return 0;
    for (i = 0; i < value->size; ++i) entry[i] = value->data[i];
    add_load_order_override( entry );
    free( entry );
    return 1;
}

static int add_override( const char *module, const char *order )
{
    WCHAR entry[64];
    size_t i, module_size = strlen( module ), order_size = strlen( order );
    if (module_size + order_size + 2 > ARRAY_SIZE(entry)) return 0;
    for (i = 0; i < module_size; ++i) entry[i] = module[i];
    entry[module_size] = '=';
    for (i = 0; i < order_size; ++i) entry[module_size + 1 + i] = order[i];
    entry[module_size + order_size + 1] = 0;
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

static int validate_backend_directory( const char *path, const char *directory,
                                       uint16_t machine, int require_winemetal,
                                       int require_dxgi )
{
    unsigned int j;
    int found = 0;
    int have_d3d11 = 0, have_dxgi = 0, have_winemetal = 0;
    for (j = 0; j < ARRAY_SIZE(graphics_modules); ++j)
    {
        char file[PATH_MAX];
        struct stat lst;
        if (snprintf( file, sizeof(file), "%s/%s/%s.dll", path,
                      directory, graphics_modules[j] ) >= (int)sizeof(file)) return 0;
        if (lstat( file, &lst ) == -1) continue;
        if (S_ISLNK( lst.st_mode ) || !pe_is_builtin_for_machine( file, machine ))
        {
            log_message( "error", "invalid PE machine/signature or symlink: %s", file );
            return 0;
        }
        if (!strcmp( graphics_modules[j], "d3d11" )) have_d3d11 = 1;
        if (!strcmp( graphics_modules[j], "dxgi" )) have_dxgi = 1;
        if (!strcmp( graphics_modules[j], "winemetal" )) have_winemetal = 1;
        found = 1;
    }
    if (!have_d3d11 || (require_dxgi && !have_dxgi) || (require_winemetal && !have_winemetal))
        log_message( "error", "backend lacks d3d11.dll%s%s for %s: %s",
                     require_dxgi ? ", dxgi.dll" : "",
                     require_winemetal ? " or winemetal.dll" : "", directory, path );
    else return found;
    return 0;
}

static int activate_backend( const struct slice *selection )
{
    char backend[16], candidate[PATH_MAX], path[PATH_MAX], support[PATH_MAX], derived_root[PATH_MAX];
    const char *direct = get_gamma_env( "GRAPHICS_BACKEND_PATH" );
    const char *root = get_gamma_env( "GRAPHICS_BACKENDS_ROOT" );
    const char *gptk = get_gamma_env( "GPTK_ROOT" );
    const char *machine_dir;
    uint16_t machine;
    unsigned int i;

    if ((!root || !*root) && engine_root_from_ntdll( derived_root )) root = derived_root;

    if (!valid_backend( selection ) || selection->size >= sizeof(backend)) return 0;
    memcpy( backend, selection->data, selection->size );
    backend[selection->size] = 0;
    if (!strcmp( backend, "default" ) || !strcmp( backend, "wined3d" ))
    {
        setenv( "CX_ACTIVE_GRAPHICS_BACKEND", "wined3d", 1 );
        log_message( "info", "graphics backend=wined3d path=<engine builtin>" );
        return 1;
    }
    if (direct && *direct)
    {
        if (!canonical_directory( direct, path ))
        {
            log_message( "error", "invalid graphics backend path: %s", direct );
            goto unavailable;
        }
    }
    else
    {
        candidate[0] = 0;
        if (!strcmp( backend, "d3dmetal" ))
        {
            if (gptk && *gptk && snprintf( candidate, sizeof(candidate), "%s/wine", gptk ) < (int)sizeof(candidate) && canonical_directory( candidate, path ))
            {
                /* gptk/wine found */
            }
            else if (root && snprintf( candidate, sizeof(candidate), "%s/lib/d3dmetal", root ) < (int)sizeof(candidate) && canonical_directory( candidate, path ))
            {
                /* root/lib/d3dmetal found */
            }
            else if (root && snprintf( candidate, sizeof(candidate), "%s/lib64/apple_gptk/wine", root ) < (int)sizeof(candidate) && canonical_directory( candidate, path ))
            {
                /* legacy cyder root/lib64/apple_gptk/wine found */
            }
            else if (root && snprintf( candidate, sizeof(candidate), "%s/lib/apple_gptk/wine", root ) < (int)sizeof(candidate) && canonical_directory( candidate, path ))
            {
                /* root/lib/apple_gptk/wine found */
            }
            else
            {
                candidate[0] = 0;
            }
        }
        else if (!strcmp( backend, "dxmt" ))
        {
            if (root && snprintf( candidate, sizeof(candidate), "%s/lib/dxmt", root ) < (int)sizeof(candidate) && canonical_directory( candidate, path ))
            {
                /* root/lib/dxmt found */
            }
            else
            {
                candidate[0] = 0;
            }
        }
        else if (root && snprintf( candidate, sizeof(candidate), "%s/lib/%s", root, backend ) < (int)sizeof(candidate) && canonical_directory( candidate, path ))
        {
            /* root/lib/<backend> found */
        }
        else
        {
            candidate[0] = 0;
        }

        if (!candidate[0] || !path[0])
        {
            log_message( "error", "graphics backend path unavailable for %s", backend );
            goto unavailable;
        }
    }
    machine_dir = current_machine_directory( &machine );
    /* DXVK ships no dxgi.dll: it pairs with Wine's builtin DXGI. */
    if (!validate_backend_directory( path, machine_dir, machine, !strcmp( backend, "dxmt" ),
                                     strcmp( backend, "dxvk" ) && strcmp( backend, "dxvk2" ) ))
        goto unavailable;
    if (!strcmp( backend, "dxvk" ) || !strcmp( backend, "dxvk2" ))
    {
        if (!root ||
            (snprintf( support, sizeof(support), "%s/lib/wine/x86_64-unix/libMoltenVK.dylib", root ) < (int)sizeof(support) &&
             access( support, R_OK ) &&
             (snprintf( support, sizeof(support), "%s/lib64/libMoltenVK.dylib", root ) >= (int)sizeof(support) ||
              access( support, R_OK ))))
        {
            log_message( "error", "DXVK MoltenVK dependency missing below engine root" );
            goto unavailable;
        }
    }
    if (!strcmp( backend, "dxmt" ))
    {
        if ((snprintf( support, sizeof(support), "%s/x86_64-unix/winemetal.so", path ) < (int)sizeof(support) && !access( support, R_OK )) ||
            (root && snprintf( support, sizeof(support), "%s/lib/wine/x86_64-unix/winemetal.so", root ) < (int)sizeof(support) && !access( support, R_OK )) ||
            (root && snprintf( support, sizeof(support), "%s/lib/dxmt/x86_64-unix/winemetal.so", root ) < (int)sizeof(support) && !access( support, R_OK )))
        {
            /* winemetal.so host bridge verified */
        }
        else
        {
            log_message( "error", "DXMT host support missing: %s", path );
            goto unavailable;
        }
    }
    if (!strcmp( backend, "d3dmetal" ) || !strcmp( backend, "gptk40b1" ) || !strcmp( backend, "gptk40b2" ) )
    {
        int have_d3dshared = 0;
        char direct_base[PATH_MAX];
        const char *base = gptk && *gptk ? gptk : NULL;
        if (!base && direct && *direct)
        {
            strcpy( direct_base, path );
            if (strrchr( direct_base, '/' )) *strrchr( direct_base, '/' ) = 0;
            base = direct_base;
        }
        if (base && snprintf( support, sizeof(support), "%s/external/libd3dshared.dylib", base ) < (int)sizeof(support) && !access( support, R_OK ))
        {
            have_d3dshared = 1;
        }
        else if (base && snprintf( support, sizeof(support), "%s/libd3dshared.dylib", base ) < (int)sizeof(support) && !access( support, R_OK ))
        {
            have_d3dshared = 1;
        }
        else if (root && snprintf( support, sizeof(support), "%s/lib/external/libd3dshared.dylib", root ) < (int)sizeof(support) && !access( support, R_OK ))
        {
            have_d3dshared = 1;
        }
        else if (root && snprintf( support, sizeof(support), "%s/lib/%s/external/libd3dshared.dylib", root, backend ) < (int)sizeof(support) && !access( support, R_OK ))
        {
            have_d3dshared = 1;
        }
        else if (root && snprintf( support, sizeof(support), "%s/lib64/apple_gptk/external/libd3dshared.dylib", root ) < (int)sizeof(support) && !access( support, R_OK ))
        {
            have_d3dshared = 1;
        }
        else if (root && snprintf( support, sizeof(support), "%s/lib/wine/x86_64-unix/d3d11.so", root ) < (int)sizeof(support) && !access( support, R_OK ))
        {
            have_d3dshared = 1;
        }

        if (!have_d3dshared)
        {
            log_message( "error", "D3DMetal libd3dshared.dylib bridge missing below engine root" );
            goto unavailable;
        }
        setenv( "CX_APPLEGPTK_LIBD3DSHARED_PATH", support, 1 );
    }
    for (i = 0; i < ARRAY_SIZE(graphics_modules); ++i)
    {
        char file32[PATH_MAX], file64[PATH_MAX];
        snprintf( file32, sizeof(file32), "%s/i386-windows/%s.dll", path, graphics_modules[i] );
        snprintf( file64, sizeof(file64), "%s/x86_64-windows/%s.dll", path, graphics_modules[i] );
        if (!access( file32, R_OK ) || !access( file64, R_OK )) add_override( graphics_modules[i], "b" );
    }
    {
        char *retained = strdup( path );
        if (!retained) goto unavailable;
        prepend_dll_path( retained ); /* ntdll keeps this pointer for process lifetime */
    }
    setenv( "CX_ACTIVE_GRAPHICS_BACKEND", backend, 1 );
    setenv( "GAMMA_ACTIVE_GRAPHICS_BACKEND_PATH", path, 1 );
    setenv( "CYDER_ACTIVE_GRAPHICS_BACKEND_PATH", path, 1 );
    log_message( "info", "graphics backend=%s machine=%s path=%s", backend, machine_dir, path );
    return 1;

unavailable:
    setenv( "CX_ACTIVE_GRAPHICS_BACKEND", "wined3d", 1 );
    unsetenv( "GAMMA_ACTIVE_GRAPHICS_BACKEND_PATH" );
    unsetenv( "CYDER_ACTIVE_GRAPHICS_BACKEND_PATH" );
    log_message( "warning", "graphics backend=%s rejected; path=%s; fallback=wined3d",
                 backend, direct && *direct ? direct : "<derived>" );
    return 0;
}

static int rule_matches( const struct rule *rule, const RTL_USER_PROCESS_PARAMETERS *params )
{
    unsigned int i;
    int path_match = 0;
    if (rule->invalid || !rule->enabled || !rule->path_count) return 0;
    for (i = 0; i < rule->path_count; ++i)
        if (path_matches( &params->ImagePathName, &rule->paths[i] )) path_match = 1;
    if (!path_match) return 0;
    for (i = 0; i < rule->forbidden_count; ++i)
        if (command_has_argument( &params->CommandLine, &rule->forbidden[i], 0 )) return 0;
    return 1;
}

static void apply_rule( const struct rule *rule, RTL_USER_PROCESS_PARAMETERS *params,
                        int graphics_forced, int *graphics_applied )
{
    unsigned int i;
    if (!rule_matches( rule, params )) return;
    for (i = 0; i < rule->arg_count; ++i) append_argument( params, &rule->args[i] );
    for (i = 0; i < rule->dll_count; ++i) add_override_slice( &rule->dlls[i] );
    if (rule->have_graphics && !graphics_forced && !*graphics_applied)
    {
        activate_backend( &rule->graphics );
        *graphics_applied = 1;
    }
}

static void parse_database( const struct database *db, RTL_USER_PROCESS_PARAMETERS *params,
                            int graphics_forced, int *graphics_applied )
{
    size_t offset = CDB_HEADER_SIZE;
    struct rule rule;
    uint32_t i;
    int in_rule = 0, have_priority = 0;
    int32_t previous_priority = INT32_MAX;

    memset( &rule, 0, sizeof(rule) );
    for (i = 0; i < db->records; ++i)
    {
        uint16_t type = get_u16( db->data + offset );
        uint16_t flags = get_u16( db->data + offset + 2 );
        uint32_t size = get_u32( db->data + offset + 4 );
        struct slice value;
        offset += 8;
        value.data = db->data + offset;
        value.size = size;
        offset += size;
        if (type == RULE_BEGIN)
        {
            memset( &rule, 0, sizeof(rule) );
            in_rule = 1;
            if (flags != CDB_REQUIRED) rule.invalid = 1;
            continue;
        }
        if (type == RULE_END)
        {
            if (flags != CDB_REQUIRED || !rule.have_id || !rule.have_priority || !rule.have_enabled)
                rule.invalid = 1;
            if (have_priority && rule.priority > previous_priority) rule.invalid = 1;
            previous_priority = rule.priority;
            have_priority = 1;
            apply_rule( &rule, params, graphics_forced, graphics_applied );
            in_rule = 0;
            continue;
        }
        if (!in_rule || flags != CDB_REQUIRED) { rule.invalid = 1; continue; }
        switch (type)
        {
        case RULE_ID: rule.have_id = valid_ascii( &value ); break;
        case PRIORITY:
            if (size == 4 && !rule.have_priority) rule.priority = (int32_t)get_u32( value.data ), rule.have_priority = 1;
            else rule.invalid = 1;
            break;
        case ENABLED:
            if (size == 1 && value.data[0] <= 1 && !rule.have_enabled)
                rule.enabled = value.data[0], rule.have_enabled = 1;
            else rule.invalid = 1;
            break;
        case MATCH_PATH_SUFFIX:
            if (rule.path_count < MAX_ITEMS) rule.paths[rule.path_count++] = value; else rule.invalid = 1;
            break;
        case MATCH_FORBIDDEN_ARG:
            if (rule.forbidden_count < MAX_ITEMS) rule.forbidden[rule.forbidden_count++] = value; else rule.invalid = 1;
            break;
        case ACTION_APPEND_ARG:
            if (rule.arg_count < MAX_ITEMS) rule.args[rule.arg_count++] = value; else rule.invalid = 1;
            break;
        case ACTION_DLL_OVERRIDE:
            if (rule.dll_count < MAX_ITEMS) rule.dlls[rule.dll_count++] = value; else rule.invalid = 1;
            break;
        case ACTION_GRAPHICS_BACKEND:
            if (!rule.have_graphics && valid_backend( &value )) rule.graphics = value, rule.have_graphics = 1;
            else rule.invalid = 1;
            break;
        case ACTION_SET_ENV: case ACTION_UNSET_ENV: case ACTION_REPLACE_EXECUTABLE:
        case ACTION_WINED3D_RENDERER:
            log_message( "warning", "unsupported CompatDB action 0x%04x ignored", type );
            break;
        default: rule.invalid = 1; break;
        }
    }
}

static void apply_default_runtime_overrides(void)
{
    /* DirectX utility and shader compiler overrides -> prefer native (from winetricks / game) */
    add_override( "*d3dcompiler_47", "native,builtin" );
    add_override( "*d3dcompiler_43", "native,builtin" );
    add_override( "*d3dx11_43", "native,builtin" );
    add_override( "*d3dx10_43", "native,builtin" );
    add_override( "*d3dx9_43", "native,builtin" );
    add_override( "*xinput1_3", "native,builtin" );

    /* Disable winemenubuilder to avoid polluting macOS LaunchServices */
    add_override( "winemenubuilder.exe", "" );
}

__attribute__((constructor))
static void compatdb_init(void)
{
    const char *disabled = get_gamma_env( "COMPATDB" );
    const char *path = get_gamma_env( "COMPATDB_PATH" );
    const char *forced = get_gamma_env( "GRAPHICS_BACKEND" );
    const char *cx_backend = getenv( "CX_ACTIVE_GRAPHICS_BACKEND" );
    const char *d3dmetal_flag = getenv( "D3DMETAL" );
    const char *dxmt_flag = getenv( "DXMT" );
    const char *dxvk_flag = getenv( "DXVK" );
    RTL_USER_PROCESS_PARAMETERS *params;
    struct database db;
    int graphics_forced = 0;
    int graphics_applied = 0;

    params = NtCurrentTeb() && NtCurrentTeb()->Peb ? NtCurrentTeb()->Peb->ProcessParameters : NULL;
    if (!params || !params->ImagePathName.Buffer || !params->CommandLine.Buffer)
    {
        log_message( "error", "current process parameters unavailable" );
        return;
    }

    /* Set default helper library overrides */
    apply_default_runtime_overrides();

    /* Check Sikarugir / CrossOver environment variables if GAMMA_GRAPHICS_BACKEND is unset */
    if ((!forced || !*forced || !strcmp( forced, "default" )))
    {
        if (d3dmetal_flag && !strcmp( d3dmetal_flag, "1" )) forced = "d3dmetal";
        else if (dxmt_flag && !strcmp( dxmt_flag, "1" )) forced = "dxmt";
        else if (dxvk_flag && !strcmp( dxvk_flag, "1" )) forced = "dxvk";
        else if (cx_backend && *cx_backend && strcmp( cx_backend, "default" )) forced = cx_backend;
    }

    if (forced && *forced && strcmp( forced, "default" ))
    {
        struct slice selection = {(const unsigned char *)forced, strlen( forced )};
        if (valid_backend( &selection ))
        {
            if (activate_backend( &selection ))
            {
                graphics_forced = 1;
                graphics_applied = 1;
            }
        }
        else log_message( "error", "invalid graphics backend: %s", forced );
    }

    if (disabled && !strcmp( disabled, "0" ))
    {
        if (!graphics_forced && !graphics_applied)
        {
            struct slice fallback = {(const unsigned char *)"d3dmetal", 8};
            if (!activate_backend( &fallback ))
            {
                struct slice fallback_wined3d = {(const unsigned char *)"wined3d", 7};
                activate_backend( &fallback_wined3d );
            }
        }
        return;
    }

    if (path && *path && load_database( path, &db ))
    {
        if (!validate_database( &db )) log_message( "error", "invalid CompatDB structure: %s", path );
        else
        {
            log_message( "info", "loaded CompatDB v1 rules=%u path=%s", db.rules, path );
            parse_database( &db, params, graphics_forced, &graphics_applied );
        }
        free( db.data );
    }

    /* If no backend was explicitly forced or applied by rule, auto-activate D3DMetal default */
    if (!graphics_forced && !graphics_applied)
    {
        struct slice default_d3dmetal = {(const unsigned char *)"d3dmetal", 8};
        if (activate_backend( &default_d3dmetal ))
        {
            graphics_applied = 1;
        }
        else
        {
            struct slice default_dxmt = {(const unsigned char *)"dxmt", 4};
            if (activate_backend( &default_dxmt ))
            {
                graphics_applied = 1;
            }
            else
            {
                struct slice fallback = {(const unsigned char *)"wined3d", 7};
                activate_backend( &fallback );
            }
        }
    }
}
