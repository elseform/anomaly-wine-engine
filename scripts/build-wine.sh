#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=0
BOOTSTRAP_BREW=0
INSTALL_DEPS=0
CONFIGURE_ONLY=0
RECONFIGURE=0
PREPARE_ONLY=0
CX_VERSION="${CX_VERSION:-26}"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
VULKAN_MODE=without
VULKAN_SOURCE=homebrew
BUILD_TESTS=0
VULKAN_SONAME_FALLBACK=0
SKIP_RENDERERS=0

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '+'
    for arg in "$@"; do
      printf ' %q' "$arg"
    done
    printf '\n'
  else
    "$@"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --bootstrap-brew) BOOTSTRAP_BREW=1 ;;
    --install-deps) INSTALL_DEPS=1 ;;
    --configure-only) CONFIGURE_ONLY=1 ;;
    --reconfigure) RECONFIGURE=1 ;;
    --skip-renderers) SKIP_RENDERERS=1 ;;
    --prepare-only) PREPARE_ONLY=1 ;;
    --with-tests) BUILD_TESTS=1 ;;
    --vulkan-soname-fallback) VULKAN_SONAME_FALLBACK=1 ;;
    --cx)
      CX_VERSION="$2"
      shift
      ;;
    --jobs)
      JOBS="$2"
      shift
      ;;
    --with-vulkan)
      VULKAN_MODE=with
      ;;
    --without-vulkan)
      VULKAN_MODE=without
      ;;
    --vulkan-source)
      VULKAN_SOURCE="$2"
      shift
      ;;
    -h | --help)
      cat <<EOF
Usage: $(basename "$0") [options]

Build the engine's Wine for macOS x86_64 (Rosetta): upstream Wine 11.16 with
patches/series applied (the CrossOver 26.3.0 port first).

Options:
  --cx 26         CrossOver release (default: 26)
  --prepare-only     Fetch, verify and extract Wine and llvm-mingw, then exit
  --with-tests       Build Wine regression-test executables (off for runtime builds)
  --bootstrap-brew   Install project-local x86_64 Homebrew
  --install-deps     Install build dependencies via .brew-x86
  --with-vulkan      Enable Vulkan (Wine configure autodetects MoltenVK)
  --without-vulkan   Disable Vulkan (Wine ./configure --without-vulkan)
  --vulkan-soname-fallback
                     Apply the optional CX26 no-Vulkan SONAME build fallback
  --vulkan-source SRC
                     With --with-vulkan: homebrew (default) or crossover
                     crossover: copy MoltenVK out of a local CrossOver.app
                     (auto-detected; override with CROSSOVER_APP)
  --configure-only   Run configure without make/install
  --reconfigure      Run configure even when it already ran with the same options
  --skip-renderers   Skip install-renderers.sh (backend cleanup of the install tree)
  --jobs N           Parallel make jobs (default: CPU count)
  --dry-run          Print commands without executing
  -h, --help         Show this help

Vulkan examples:
  bash scripts/build-wine.sh --install-deps --without-vulkan
  bash scripts/build-wine.sh --install-deps --with-vulkan --vulkan-source homebrew
  bash scripts/build-wine.sh --with-vulkan --vulkan-source crossover

vulkan-source crossover copies libMoltenVK.dylib (x86_64) out of a local
CrossOver.app into the graphics staging tree, then bundles it into the
engine. This repo does not build MoltenVK itself. Vulkan support is
independent of the two packaged renderer choices.
EOF
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
  shift
done

case "$CX_VERSION" in
  25)
    echo "CX25 support was retired; this tree only builds CrossOver 26." >&2
    exit 1
    ;;
  26) ;;
  *)
    echo "Unknown --cx value: $CX_VERSION (expected 26)" >&2
    exit 1
    ;;
esac

case "$VULKAN_SOURCE" in
  homebrew | crossover) ;;
  *)
    echo "Unknown --vulkan-source: $VULKAN_SOURCE (expected homebrew or crossover)" >&2
    exit 1
    ;;
esac

if [[ "$VULKAN_MODE" == "without" && "$VULKAN_SOURCE" != "homebrew" ]]; then
  echo "--vulkan-source is only valid with --with-vulkan" >&2
  exit 1
fi

if [[ "$VULKAN_SONAME_FALLBACK" -eq 1 && "$VULKAN_MODE" != "without" ]]; then
  echo "--vulkan-soname-fallback requires --without-vulkan" >&2
  exit 1
fi

export CX_VERSION
source "$SCRIPT_DIR/env-x86_64.sh"

PREPARE_ARGS=()
[[ "$DRY_RUN" -eq 1 ]] && PREPARE_ARGS+=(--dry-run)
"$SCRIPT_DIR/prepare-build-deps.sh" ${PREPARE_ARGS[@]+"${PREPARE_ARGS[@]}"}


if [[ "$PREPARE_ONLY" -eq 1 ]]; then
  exit 0
fi

bootstrap_brew() {
  if [[ -x "$HOMEBREW_PREFIX/bin/brew" ]]; then
    echo "Homebrew already present at $HOMEBREW_PREFIX"
    return 0
  fi

  run mkdir -p "$HOMEBREW_PREFIX"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "+ curl -L https://github.com/Homebrew/brew/tarball/master | tar xz --strip-components=1 -C $HOMEBREW_PREFIX"
    return 0
  fi

  curl -L https://github.com/Homebrew/brew/tarball/master \
    | tar xz --strip-components=1 -C "$HOMEBREW_PREFIX"
  # Ensure brew metadata points at the project prefix, not /opt/homebrew.
  brew_x86 update --force --quiet 2>/dev/null || true
}

if [[ "$BOOTSTRAP_BREW" -eq 1 ]]; then
  bootstrap_brew
fi

if [[ "$INSTALL_DEPS" -eq 1 ]]; then
  if [[ ! -x "$HOMEBREW_PREFIX/bin/brew" && "$DRY_RUN" -eq 0 ]]; then
    echo "Missing $HOMEBREW_PREFIX/bin/brew; run with --bootstrap-brew first" >&2
    exit 1
  fi
  # Build tools may use bottles (host minos OK — not shipped in the engine).
  BUILD_TOOL_DEPS=(autoconf bison flex pkgconf)
  # Runtime libs are copied into lib/wine/x86_64-unix and must be ≤ product floor.
  RUNTIME_DEPS=(zlib bzip2 libpng freetype gettext libffi gnutls)
  if [[ "$VULKAN_MODE" == "with" ]]; then
    case "$VULKAN_SOURCE" in
      homebrew)
        # molten-vk bottles are not used for the CrossOver renderer path; still
        # build from source if someone explicitly selects Homebrew MoltenVK.
        RUNTIME_DEPS+=(molten-vk)
        BUILD_TOOL_DEPS+=(vulkan-headers)
        ;;
      crossover)
        BUILD_TOOL_DEPS+=(cmake python3)
        ;;
    esac
  fi
  run brew_x86 install "${BUILD_TOOL_DEPS[@]}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "+ brew_x86_install_runtime ${RUNTIME_DEPS[*]}"
  else
    brew_x86_install_runtime "${RUNTIME_DEPS[@]}"
  fi
  if [[ "$VULKAN_MODE" == "with" && "$VULKAN_SOURCE" == "crossover" ]]; then
    echo "CrossOver Vulkan: libMoltenVK.dylib is copied from ${CROSSOVER_APP:-a local CrossOver.app} into $GRAPHICS_INSTALL/lib."
  fi
fi

# Sanitize PATH so configure/make never pick /opt/homebrew (arm64) pkg-config/libs.
BUILD_PATH="$LLVM_MINGW/bin:$HOMEBREW_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin"
# keg-only formulae ship .pc under opt/*/lib/pkgconfig
PKG_PC_PATH="$HOMEBREW_PREFIX/lib/pkgconfig:${HOMEBREW_PREFIX}/opt/zlib/lib/pkgconfig:${HOMEBREW_PREFIX}/opt/bzip2/lib/pkgconfig"

require_moltenvk_homebrew() {
  local lib
  for lib in \
    "$HOMEBREW_PREFIX/opt/molten-vk/lib/libMoltenVK.dylib" \
    "$HOMEBREW_PREFIX/lib/libMoltenVK.dylib"; do
    if [[ -f "$lib" ]]; then
      return 0
    fi
  done
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "+ require libMoltenVK.dylib in $HOMEBREW_PREFIX"
    return 0
  fi
  echo "Missing x86_64 libMoltenVK.dylib in $HOMEBREW_PREFIX." >&2
  echo "Re-run: bash scripts/build-wine.sh --install-deps --with-vulkan --vulkan-source homebrew" >&2
  exit 1
}

require_moltenvk_crossover() {
  local lib="$GRAPHICS_INSTALL/lib/libMoltenVK.dylib"
  if [[ -f "$lib" ]]; then
    return 0
  fi
  # Stage a copy out of a local CrossOver.app when one is installed. Always a
  # real copy: the engine tree must never reference CrossOver.app at runtime.
  if [[ -n "${CROSSOVER_MOLTENVK:-}" && -f "$CROSSOVER_MOLTENVK" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "+ cp $CROSSOVER_MOLTENVK $lib"
      return 0
    fi
    mkdir -p "$GRAPHICS_INSTALL/lib"
    cp "$CROSSOVER_MOLTENVK" "$lib"
    chmod u+w "$lib"
    echo "Staged libMoltenVK.dylib from $CROSSOVER_APP"
    return 0
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "+ require $lib in GRAPHICS_INSTALL"
    return 0
  fi
  echo "Missing $lib" >&2
  echo "Install CrossOver.app (auto-detected in ~/Applications or /Applications)," >&2
  echo "set CROSSOVER_APP to its location, or point GRAPHICS_INSTALL at a tree" >&2
  echo "that already contains lib/libMoltenVK.dylib." >&2
  echo "Alternative: --vulkan-source homebrew (brew install molten-vk)." >&2
  exit 1
}

# Homebrew bzip2 is keg-only and may not install a .pc file; freetype2.pc needs it.
ensure_bzip2_pc() {
  local pc="$HOMEBREW_PREFIX/lib/pkgconfig/bzip2.pc"
  local prefix="$HOMEBREW_PREFIX/opt/bzip2"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "+ ensure $pc"
    return 0
  fi
  if [[ -f "$pc" || -f "$prefix/lib/pkgconfig/bzip2.pc" ]]; then
    return 0
  fi
  if [[ ! -d "$prefix" ]]; then
    echo "Missing $prefix; re-run with --install-deps" >&2
    exit 1
  fi
  mkdir -p "$HOMEBREW_PREFIX/lib/pkgconfig"
  cat > "$pc" <<EOF
prefix=$prefix
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: bzip2
Description: bzip2 compression library
Version: 1.0.8
Libs: -L\${libdir} -lbz2
Cflags: -I\${includedir}
EOF
  echo "wrote $pc (homebrew bzip2 is keg-only without a .pc)"
}

require_x86_dep() {
  local pc="$1"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "+ require pkg-config $pc via $HOMEBREW_PREFIX"
    return 0
  fi
  if [[ ! -x "$HOMEBREW_PREFIX/bin/pkg-config" ]]; then
    echo "Missing $HOMEBREW_PREFIX/bin/pkg-config; re-run with --install-deps" >&2
    exit 1
  fi
  if ! arch -x86_64 env PATH="$BUILD_PATH" PKG_CONFIG_PATH="$PKG_PC_PATH" \
      "$HOMEBREW_PREFIX/bin/pkg-config" --exists "$pc"; then
    echo "Missing x86_64 $pc in $HOMEBREW_PREFIX (not /opt/homebrew)." >&2
    arch -x86_64 env PATH="$BUILD_PATH" PKG_CONFIG_PATH="$PKG_PC_PATH" \
      "$HOMEBREW_PREFIX/bin/pkg-config" --exists --print-errors "$pc" 2>&1 || true
    echo "Re-run: bash scripts/build-wine.sh --install-deps" >&2
    exit 1
  fi
}

ensure_bzip2_pc
require_x86_dep freetype2
CONFIGURE_VULKAN_FLAG=()
if [[ "$VULKAN_MODE" == "without" ]]; then
  CONFIGURE_VULKAN_FLAG=(--without-vulkan)
fi

VULKAN_LIB_PATHS=()
VULKAN_PKG_PC_PATH="$PKG_PC_PATH"

if [[ "$VULKAN_MODE" == "with" ]]; then
  case "$VULKAN_SOURCE" in
    homebrew)
      require_moltenvk_homebrew
      VULKAN_LIB_PATHS+=("$HOMEBREW_PREFIX/opt/molten-vk/lib" "$HOMEBREW_PREFIX/lib")
      if [[ -d "$HOMEBREW_PREFIX/opt/molten-vk/lib/pkgconfig" ]]; then
        VULKAN_PKG_PC_PATH="$HOMEBREW_PREFIX/opt/molten-vk/lib/pkgconfig:$VULKAN_PKG_PC_PATH"
      fi
      ;;
    crossover)
      require_moltenvk_crossover
      VULKAN_LIB_PATHS+=("$GRAPHICS_INSTALL/lib")
      ;;
  esac
fi

if [[ ${#VULKAN_LIB_PATHS[@]} -gt 0 ]]; then
  for _vulkan_lib in "${VULKAN_LIB_PATHS[@]}"; do
    PKG_PC_PATH="$_vulkan_lib/pkgconfig:$PKG_PC_PATH"
    export LIBRARY_PATH="${_vulkan_lib}${LIBRARY_PATH:+:$LIBRARY_PATH}"
  done
  unset _vulkan_lib
fi

run mkdir -p "$OGOM/install" "$WINE_SRC/build64"
# Dry-run only prints mkdir; still create dirs so subsequent cd works.
mkdir -p "$OGOM/install" "$WINE_SRC/build64"

cd "$WINE_SRC"

# Apply patches/series (CrossOver port, then the engine patches) and regenerate
# configure. Re-runs skip what the tree already records; see the script.
SERIES_ARGS=(--src "$WINE_SRC")
[[ "$VULKAN_MODE" == "with" ]] && SERIES_ARGS+=(--with-vulkan)
[[ "$DRY_RUN" -eq 1 ]] && SERIES_ARGS+=(--dry-run)
"$SCRIPT_DIR/apply-wine-series.sh" "${SERIES_ARGS[@]}"

# The release tarball is not a git checkout; make_makefiles requires `git ls-files`.
# Regenerators are only needed when hacking the wine tree as a git worktree.
if [[ -e "$WINE_SRC/.git" || -n "${GIT_DIR:-}" ]]; then
  run ./tools/make_requests
  run ./tools/make_specfiles
  run ./tools/make_makefiles
  run arch -x86_64 env PATH="$BUILD_PATH" autoreconf -f
else
  echo "Non-git wine tree; skipping make_requests/make_specfiles/make_makefiles/autoreconf"
fi

cd "$WINE_SRC/build64"

# Bake -mmacosx-version-min into host CFLAGS so incremental `make` without an
# exported MACOSX_DEPLOYMENT_TARGET still cannot drift to the SDK default (15+).
GAMMA_MIN_OS_TARGET="${MACOSX_DEPLOYMENT_TARGET:-10.15}"
GAMMA_MIN_FLAG="${GAMMA_MACOSX_VERSION_MIN_FLAG:--mmacosx-version-min=${GAMMA_MIN_OS_TARGET}}"
GAMMA_HOST_CFLAGS="-arch x86_64 ${CFLAGS:--g -O2} ${GAMMA_MIN_FLAG}"
GAMMA_HOST_OBJCFLAGS="-arch x86_64 ${OBJCFLAGS:--g -O2} ${GAMMA_MIN_FLAG}"
GAMMA_HOST_LDFLAGS="-arch x86_64 ${LDFLAGS:-} ${GAMMA_MIN_FLAG}"

# configure enables any function the build Mac's SDK exports. Functions newer
# than the product floor are weak-linked and NULL on an older macOS, so they are
# pinned off here; check-sdk-availability.py below refuses any it finds.
#   pipe2: macOS 27.0 SDK (ntdll server_pipe, process creation, msv1_0)
CONFIGURE_CACHE_PINS=(
  ac_cv_func_pipe2=no
)

CONFIGURE_CMD=(
  arch -x86_64 env
  PATH="$BUILD_PATH"
  BISON="$HOMEBREW_PREFIX/opt/bison/bin/bison"
  PKG_CONFIG="$HOMEBREW_PREFIX/bin/pkg-config"
  PKG_CONFIG_PATH="$VULKAN_PKG_PC_PATH"
  LIBRARY_PATH="${LIBRARY_PATH:-}"
  MACOSX_DEPLOYMENT_TARGET="$GAMMA_MIN_OS_TARGET"
  CFLAGS="$GAMMA_HOST_CFLAGS"
  OBJCFLAGS="$GAMMA_HOST_OBJCFLAGS"
  LDFLAGS="$GAMMA_HOST_LDFLAGS"
  ../configure
  -C
  --enable-win64
  --enable-archs=i386,x86_64
  --with-mingw=llvm-mingw
  --prefix="$WINE_INSTALL"
  "${CONFIGURE_CACHE_PINS[@]}"
)
if [[ "$BUILD_TESTS" -eq 0 ]]; then
  CONFIGURE_CMD+=(--disable-tests)
fi
if [[ ${#CONFIGURE_VULKAN_FLAG[@]} -gt 0 ]]; then
  CONFIGURE_CMD+=("${CONFIGURE_VULKAN_FLAG[@]}")
fi

echo "configure command:"
printf '  '
for arg in "${CONFIGURE_CMD[@]}"; do
  printf '%q ' "$arg"
done
printf '\n'
echo "host minOS: MACOSX_DEPLOYMENT_TARGET=$GAMMA_MIN_OS_TARGET ($GAMMA_MIN_FLAG)"

# Resume: when build64 was already configured with exactly these options
# against the current configure script, go straight to make, which continues
# from whatever it compiled before. The stamp is written only after configure
# succeeds; a newly applied patch regenerates configure and so invalidates it.
CONFIGURE_STAMP="$WINE_SRC/build64/.gamma-configure"
CONFIGURE_KEY="$(printf '%q ' "${CONFIGURE_CMD[@]}")"
if [[ "$RECONFIGURE" -eq 0 && -f config.status && -f "$CONFIGURE_STAMP" &&
      config.status -nt ../configure && "$(cat "$CONFIGURE_STAMP")" == "$CONFIGURE_KEY" ]]; then
  echo "configure already ran with these options; resuming (--reconfigure to force)"
else
  rm -f "$CONFIGURE_STAMP"
  run "${CONFIGURE_CMD[@]}"
  [[ "$DRY_RUN" -eq 1 ]] || printf '%s\n' "$CONFIGURE_KEY" >"$CONFIGURE_STAMP"
fi
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "+ $SCRIPT_DIR/check-sdk-availability.py include/config.h $GAMMA_PRODUCT_MIN_OS"
else
  python3 "$SCRIPT_DIR/check-sdk-availability.py" include/config.h "$GAMMA_PRODUCT_MIN_OS"
fi

if [[ "$CONFIGURE_ONLY" -eq 0 ]]; then
  run arch -x86_64 env PATH="$BUILD_PATH" PKG_CONFIG_PATH="$VULKAN_PKG_PC_PATH" \
    LIBRARY_PATH="${LIBRARY_PATH:-}" MACOSX_DEPLOYMENT_TARGET="$GAMMA_MIN_OS_TARGET" \
    CFLAGS="$GAMMA_HOST_CFLAGS" OBJCFLAGS="$GAMMA_HOST_OBJCFLAGS" LDFLAGS="$GAMMA_HOST_LDFLAGS" \
    make -j"$JOBS"
  run arch -x86_64 env PATH="$BUILD_PATH" PKG_CONFIG_PATH="$VULKAN_PKG_PC_PATH" \
    LIBRARY_PATH="${LIBRARY_PATH:-}" MACOSX_DEPLOYMENT_TARGET="$GAMMA_MIN_OS_TARGET" \
    CFLAGS="$GAMMA_HOST_CFLAGS" OBJCFLAGS="$GAMMA_HOST_OBJCFLAGS" LDFLAGS="$GAMMA_HOST_LDFLAGS" \
    make install
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "+ $SCRIPT_DIR/build-cxcompatdb.sh"
  else
    WINE_SRC="$WINE_SRC" WINE_INSTALL="$WINE_INSTALL" "$SCRIPT_DIR/build-cxcompatdb.sh"
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "+ GRAPHICS_INSTALL=${GRAPHICS_INSTALL:-} VULKAN_MODE=$VULKAN_MODE $SCRIPT_DIR/bundle-wine-dylibs.sh"
  else
    GRAPHICS_INSTALL="$GRAPHICS_INSTALL" \
      VULKAN_MODE="$VULKAN_MODE" VULKAN_SOURCE="$VULKAN_SOURCE" \
      "$SCRIPT_DIR/bundle-wine-dylibs.sh" "$WINE_INSTALL"
  fi
  if [[ "$SKIP_RENDERERS" -eq 1 ]]; then
    echo "Skipping backend cleanup of the install tree (--skip-renderers)"
  elif [[ "$DRY_RUN" -eq 1 ]]; then
    echo "+ $SCRIPT_DIR/install-renderers.sh $WINE_INSTALL"
  else
    "$SCRIPT_DIR/install-renderers.sh" "$WINE_INSTALL"
  fi
  ENGINE_VERSION_LABEL="$(head -n 1 "$SCRIPT_DIR/../config/engine-version.txt" 2>/dev/null || true)"
  if [[ -n "$ENGINE_VERSION_LABEL" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "+ write engine version $ENGINE_VERSION_LABEL to $WINE_INSTALL/version"
    else
      printf '%s\n' "$ENGINE_VERSION_LABEL" >"$WINE_INSTALL/version"
      echo "Wrote engine version: $WINE_INSTALL/version"
    fi
  fi
fi
