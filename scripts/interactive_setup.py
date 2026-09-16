#!/usr/bin/env python3
"""Interactive setup: builds a macOS .app around the packaged Wine engine.

Bundle layout:
  <App>.app/Contents/MacOS/launcher        thin launcher, paths baked in
  <App>.app/Contents/MacOS/winetricks      prefix-aware winetricks launcher
  <App>.app/Contents/Resources/engine/     engine tree (read-only, signed)

Mutable state lives outside the bundle so the app stays signable and
replaceable:
  ~/Library/Application Support/<App>/prefix    Wine prefix
  ~/Library/Application Support/<App>/app.env   user-editable settings

Standalone — does not call other scripts in this repo. Stdlib-only: no
third-party Python dependencies, so this still works from just a released
archive on a machine that has never seen this repo (only `python3` itself,
plus the same external tools the previous bash version needed: wine, tar,
zstd, winetricks, codesign, osascript, lsregister).

Every prompt below has a matching flag (see --help). Any flag given skips
its prompt; anything left unset still prompts interactively — fully
interactive, fully flag-driven, and mixed all work through the same code
path. Pass --json to emit newline-delimited JSON progress events instead of
plain text (matching gamma-setup-tool's SetupEngineEvent schema) for
programmatic driving; --json requires every input to be supplied via flags
(including --yes), since it never blocks on stdin.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent

JSON_MODE = False
_CURRENT_STAGE = None


class SetupError(RuntimeError):
    pass


# ---------------------------------------------------------------------------
# Event/log emission (text banners in plain mode, SetupEngineEvent-shaped
# newline-delimited JSON in --json mode).
# ---------------------------------------------------------------------------

def _emit(event: dict) -> None:
    print(json.dumps(event), flush=True)


def log(message: str, *, severity: str = "info") -> None:
    if JSON_MODE:
        _emit({"type": "log", "message": message, "severity": severity})
    else:
        print(message)


def err(message: str) -> None:
    if JSON_MODE:
        _emit({"type": "log", "message": message, "severity": "error"})
    else:
        print(message, file=sys.stderr)


def stage_started(stage: str, message: str = None) -> None:
    global _CURRENT_STAGE
    _CURRENT_STAGE = stage
    if JSON_MODE:
        _emit({"type": "stageStarted", "stage": stage, "message": message})
    else:
        print(f"\n{message or ('==> ' + stage)}")


def stage_finished(stage: str, message: str = None) -> None:
    if JSON_MODE:
        _emit({"type": "stageFinished", "stage": stage, "message": message})


def stage_failed(stage: str, message: str) -> None:
    if JSON_MODE:
        _emit({"type": "stageFailed", "stage": stage, "message": message, "severity": "error"})


def artifact_event(path: Path) -> None:
    if JSON_MODE:
        _emit({"type": "artifact", "path": str(path)})


def completed(success: bool, message: str = None) -> None:
    if JSON_MODE:
        _emit({"type": "completed", "success": success, "message": message})
    elif message:
        print(message)


# ---------------------------------------------------------------------------
# Prompt helpers
# ---------------------------------------------------------------------------

def prompt(message: str, default: str, override: str = None) -> str:
    if override is not None:
        log(f"{message} [{default}]: {override}")
        return override
    if JSON_MODE:
        raise SetupError(
            f"missing required value for '{message}' in --json mode "
            f"(pass the corresponding flag; --json never blocks on stdin)"
        )
    reply = input(f"{message} [{default}]: ").strip()
    return reply or default


def confirm_yes_no(message: str, default_yes: bool) -> bool:
    if JSON_MODE:
        raise SetupError(f"confirmation required for '{message}' in --json mode")
    suffix = "[Y/n]" if default_yes else "[y/N]"
    reply = input(f"{message} {suffix}: ").strip().lower()
    if not reply:
        return default_yes
    return reply.startswith("y")


# ---------------------------------------------------------------------------
# Subprocess helpers
# ---------------------------------------------------------------------------

def run(cmd, *, env: dict = None, cwd=None, check: bool = True, quiet: bool = False,
        input_text: str = None):
    proc_env = os.environ.copy()
    if env:
        proc_env.update(env)
    if input_text is not None:
        proc = subprocess.run(
            cmd, cwd=cwd, env=proc_env, input=input_text, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        )
        output = proc.stdout or ""
        for line in output.splitlines():
            if not quiet:
                log(line)
        returncode = proc.returncode
    else:
        proc = subprocess.Popen(
            cmd, cwd=cwd, env=proc_env, text=True, bufsize=1,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        )
        lines = []
        for line in proc.stdout:
            line = line.rstrip("\n")
            lines.append(line)
            if not quiet:
                log(line)
        proc.wait()
        returncode = proc.returncode
        output = "\n".join(lines)
    if check and returncode != 0:
        raise SetupError(f"command failed ({returncode}): {' '.join(str(c) for c in cmd)}\n{output}")
    return returncode, output


# ---------------------------------------------------------------------------
# Batched registry writes. Each `wine reg add` is its own full Rosetta+Wine
# process spawn (visible as one "gamma-cxcompatdb:info: ..." line per call in
# --json log output) — with ~30 redist DLL overrides alone, that was ~36
# separate process launches serialized end to end, the actual cause of the
# "Step 2.4" phase taking minutes instead of seconds. One `regedit /S` import
# applies all of them in a single process launch.
# ---------------------------------------------------------------------------

_PENDING_REG = []


def queue_reg(key_path: str, name: str, reg_type: str, data: str) -> None:
    _PENDING_REG.append((key_path, name, reg_type, data))


def _reg_escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')


def flush_reg_queue(engine_dir: Path, wineprefix: Path) -> None:
    global _PENDING_REG
    if not _PENDING_REG:
        return
    grouped = {}
    for key_path, name, reg_type, data in _PENDING_REG:
        grouped.setdefault(key_path, []).append((name, reg_type, data))
    # REGEDIT4 (not "Windows Registry Editor Version 5.00"): plain ASCII/UTF-8
    # text, no UTF-16 BOM required — simpler to write correctly and Wine's
    # regedit has always supported this classic format.
    lines = ["REGEDIT4", ""]
    for key_path, entries in grouped.items():
        lines.append(f"[{key_path}]")
        for name, reg_type, data in entries:
            if reg_type == "REG_DWORD":
                lines.append(f'"{_reg_escape(name)}"=dword:{int(data):08x}')
            else:
                lines.append(f'"{_reg_escape(name)}"="{_reg_escape(data)}"')
        lines.append("")
    with tempfile.NamedTemporaryFile("w", suffix=".reg", delete=False) as handle:
        handle.write("\n".join(lines) + "\n")
        reg_path = handle.name
    try:
        run(wine_cmd(engine_dir, "regedit", "/S", reg_path), env={"WINEPREFIX": str(wineprefix)}, quiet=True)
    finally:
        os.unlink(reg_path)
    _PENDING_REG = []


def x64(*args) -> list:
    return ["arch", "-x86_64", *[str(a) for a in args]]


def wine_cmd(engine_dir: Path, *args) -> list:
    return x64(str(engine_dir / "bin/wine"), *args)


def wineserver_cmd(engine_dir: Path, *args) -> list:
    return x64(str(engine_dir / "bin/wineserver"), *args)


# ---------------------------------------------------------------------------
# Archive extraction (tar --strip-components=1 equivalent)
# ---------------------------------------------------------------------------

def _extract_stripped(tf: tarfile.TarFile, dest: Path) -> None:
    for member in tf:
        parts = member.name.split("/", 1)
        if len(parts) < 2 or not parts[1]:
            continue
        member.name = parts[1]
        tf.extract(member, path=str(dest))


def resolve_zstd() -> str:
    for candidate in (shutil.which("zstd"), "/opt/homebrew/bin/zstd", "/usr/local/bin/zstd"):
        if candidate and os.access(candidate, os.X_OK):
            return candidate
    return None


def extract_archive(artifact_path: Path, engine_dir: Path) -> None:
    engine_dir.mkdir(parents=True, exist_ok=True)
    name = artifact_path.name
    if name.endswith(".tar.zst"):
        zstd_bin = resolve_zstd()
        if not zstd_bin:
            raise SetupError(f"zstd is required to extract {artifact_path} (brew install zstd)")
        proc = subprocess.Popen([zstd_bin, "-dc", str(artifact_path)], stdout=subprocess.PIPE)
        try:
            with tarfile.open(fileobj=proc.stdout, mode="r|") as tf:
                _extract_stripped(tf, engine_dir)
        finally:
            if proc.stdout:
                proc.stdout.close()
            returncode = proc.wait()
            if returncode != 0:
                raise SetupError(f"zstd exited with status {returncode}")
    elif name.endswith(".tar.xz"):
        with tarfile.open(str(artifact_path), mode="r:xz") as tf:
            _extract_stripped(tf, engine_dir)
    else:
        raise SetupError(f"Unsupported engine archive: {artifact_path} (expected .tar.zst or .tar.xz)")


# ---------------------------------------------------------------------------
# winetricks resolution/execution (setup-time, distinct from the generated
# app's own Contents/MacOS/winetricks launcher written later)
# ---------------------------------------------------------------------------

def resolve_winetricks(app_support: Path) -> str:
    env_bin = os.environ.get("WINETRICKS_BIN")
    if env_bin and os.access(env_bin, os.X_OK):
        return env_bin
    for candidate in ("/opt/homebrew/bin/winetricks", "/usr/local/bin/winetricks"):
        if os.access(candidate, os.X_OK):
            return candidate
    which = shutil.which("winetricks")
    if which:
        return which
    cache_dir = app_support / "cache/winetricks"
    candidate = cache_dir / "winetricks"
    if not os.access(candidate, os.X_OK):
        cache_dir.mkdir(parents=True, exist_ok=True)
        err("  Downloading current winetricks script...")
        url = "https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks"
        if not _download(url, candidate, retries=2):
            if candidate.exists():
                candidate.unlink()
            return None
        os.chmod(candidate, 0o755)
    return str(candidate)


def _download(url: str, dest: Path, retries: int = 2) -> bool:
    last_error = None
    for _ in range(retries + 1):
        try:
            urllib.request.urlretrieve(url, str(dest))
            return True
        except (urllib.error.URLError, OSError) as exc:
            last_error = exc
    err(f"  download failed: {url}: {last_error}")
    return False


_WINE_WRAPPER_SCRIPT = """#!/usr/bin/env bash
set -euo pipefail
binary="$(basename "$0")"
if [[ "$binary" == "wine64" && ! -x "$GAMMA_WINETRICKS_ENGINE/bin/wine64" ]]; then
  binary=wine
fi
exec arch -x86_64 "$GAMMA_WINETRICKS_ENGINE/bin/$binary" "$@"
"""


def run_winetricks_now(winetricks_bin: str, engine_dir: Path, wineprefix: Path,
                        app_support: Path, args: list) -> None:
    with tempfile.TemporaryDirectory(prefix="gamma-winetricks.") as wrap_dir_str:
        wrap_dir = Path(wrap_dir_str)
        wrapper = wrap_dir / "wine-wrapper"
        wrapper.write_text(_WINE_WRAPPER_SCRIPT)
        os.chmod(wrapper, 0o755)
        for name in ("wine", "wine64", "wineserver"):
            (wrap_dir / name).symlink_to("wine-wrapper")
        env = {
            "GAMMA_WINETRICKS_ENGINE": str(engine_dir),
            "WINEPREFIX": str(wineprefix),
            "WINE": str(wrap_dir / "wine"),
            "WINE64": str(wrap_dir / "wine64"),
            "WINESERVER": str(wrap_dir / "wineserver"),
            "WINELOADER": str(wrap_dir / "wine"),
            "W_CACHE": str(app_support / "cache/winetricks/downloads"),
            "PATH": f"{wrap_dir}:{os.environ.get('PATH', '')}",
        }
        run([winetricks_bin, *args], env=env, check=True)


# ---------------------------------------------------------------------------
# Generated bundle file templates (tokens avoid clashing with the literal
# bash ${...} syntax these files must keep for their own runtime).
# ---------------------------------------------------------------------------

_LAUNCHER_TEMPLATE = """#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE_DIR="$APP_DIR/Contents/Resources/engine"
APP_SUPPORT="@@APP_SUPPORT@@"
CONFIG_FILE="$APP_SUPPORT/app.env"

export WINEPREFIX="$APP_SUPPORT/prefix"

# User settings (outside the bundle) win over the defaults below.
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

export GAMMA_GRAPHICS_BACKEND="${GAMMA_GRAPHICS_BACKEND:-@@GRAPHICS_BACKEND@@}"
export WINEMSYNC="${WINEMSYNC:-1}"
export WINEESYNC="${WINEESYNC:-1}"
export ROSETTA_ADVERTISE_AVX="${ROSETTA_ADVERTISE_AVX:-0}"
export MTL_HUD_ENABLED="${MTL_HUD_ENABLED:-0}"
export WINEDEBUG="${WINEDEBUG:--all}"
export WINEBOOT_HIDE_DIALOG=1
export LC_ALL="en_US.UTF-8"
export LANG="en_US.UTF-8"

# D3DMetal needs its framework and shared library located explicitly. Only
# export them for D3DMetal; forcing them during a DXMT run points the process
# at the wrong renderer.
case "$GAMMA_GRAPHICS_BACKEND" in
  d3dmetal)
    if [[ -f "$ENGINE_DIR/lib64/apple_gptk/external/libd3dshared.dylib" ]]; then
      export CX_APPLEGPTK_LIBD3DSHARED_PATH="$ENGINE_DIR/lib64/apple_gptk/external/libd3dshared.dylib"
    fi
    if [[ -d "$ENGINE_DIR/lib64/apple_gptk/external/D3DMetal.framework" ]]; then
      export CX_D3DMETALPATH="$ENGINE_DIR/lib64/apple_gptk/external/D3DMetal.framework"
    fi
    ;;
esac

# NGX/DLSS shim files, per backend: D3DM_ENABLE_METALFX (D3DMetal) and
# DXMT_ENABLE_NVEXT (DXMT, gates dxgi.cpp's InitializeVendorExtensionNV)
# each additionally place their own backend's nvngx.dll (D3DMetal's is
# renamed from nvngx-on-metalfx by install-renderers.sh) and nvapi64.dll
# directly in the prefix's system32 — some NGX/DLSS detection paths check
# for the files there, not just Wine's own DLL search path (which already
# resolves them from lib64/apple_gptk or lib/dxmt via cxcompatdb regardless
# of these toggles). Whatever was already at those two names in system32
# gets backed up as <name>.old before being overwritten, and restored the
# moment neither toggle applies (backend switch or the toggle going back
# off); a name with no prior file is just removed again on disable.
GAMMA_NVNGX_SYSTEM32="$WINEPREFIX/drive_c/windows/system32"
if [[ -d "$GAMMA_NVNGX_SYSTEM32" ]]; then
  GAMMA_NVNGX_SRC_DIR=""
  case "$GAMMA_GRAPHICS_BACKEND" in
    dxmt)
      if [[ "${DXMT_ENABLE_NVEXT:-0}" == "1" ]]; then
        GAMMA_NVNGX_SRC_DIR="$ENGINE_DIR/lib/dxmt/x86_64-windows"
      fi
      ;;
    d3dmetal)
      if [[ "${D3DM_ENABLE_METALFX:-0}" == "1" ]]; then
        GAMMA_NVNGX_SRC_DIR="$ENGINE_DIR/lib64/apple_gptk/wine/x86_64-windows"
      fi
      ;;
  esac
  if [[ -n "$GAMMA_NVNGX_SRC_DIR" ]]; then
    for module in nvngx nvapi64; do
      src="$GAMMA_NVNGX_SRC_DIR/$module.dll"
      dst="$GAMMA_NVNGX_SYSTEM32/$module.dll"
      [[ -f "$src" ]] || continue
      if [[ ! -f "$dst.old" && -f "$dst" ]]; then
        mv "$dst" "$dst.old"
      fi
      cp -f "$src" "$dst"
    done
  else
    for module in nvngx nvapi64; do
      dst="$GAMMA_NVNGX_SYSTEM32/$module.dll"
      if [[ -f "$dst.old" ]]; then
        mv -f "$dst.old" "$dst"
      elif [[ -f "$dst" ]]; then
        rm -f "$dst"
      fi
    done
  fi
fi

GAMMA_RETINA_MODE="${GAMMA_RETINA_MODE:-N}"
WINEPREFIX="$WINEPREFIX" arch -x86_64 "$ENGINE_DIR/bin/wine" reg add \\
  "HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver" /v RetinaMode /t REG_SZ /d "$GAMMA_RETINA_MODE" /f \\
  >/dev/null 2>&1 || true
if [[ "$GAMMA_RETINA_MODE" == "Y" && -n "${GAMMA_RETINA_LOGPIXELS:-}" ]]; then
  WINEPREFIX="$WINEPREFIX" arch -x86_64 "$ENGINE_DIR/bin/wine" reg add \\
    "HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver" /v LogPixels /t REG_DWORD /d "$GAMMA_RETINA_LOGPIXELS" /f \\
    >/dev/null 2>&1 || true
fi

EXE_PATH="${EXE_PATH:-@@EXE_WIN_PATH@@}"
EXE_RUN_DIR="${EXE_RUN_DIR:-@@EXE_RUN_DIR@@}"

cd "$EXE_RUN_DIR"

# bash 3.2 on macOS chokes on "${@}" under set -u when empty
if [[ $# -eq 0 && -n "${DEFAULT_GAME_ARGS:-}" ]]; then
  # shellcheck disable=SC2086
  set -- $DEFAULT_GAME_ARGS
fi

exec taskpolicy -l 0 -t 0 arch -x86_64 "$ENGINE_DIR/bin/wine" "$EXE_PATH" "$@"
"""

_WINETRICKS_LAUNCHER_TEMPLATE = """#!/usr/bin/env bash
# Runs winetricks against this app's prefix with its bundled Wine engine.
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE_DIR="$APP_DIR/Contents/Resources/engine"
APP_SUPPORT="@@APP_SUPPORT@@"
export WINEPREFIX="@@WINEPREFIX@@"

if [[ ! -x "$ENGINE_DIR/bin/wine" || ! -x "$ENGINE_DIR/bin/wineserver" ]]; then
  echo "error: bundled Wine engine is incomplete: $ENGINE_DIR" >&2
  exit 1
fi

WINETRICKS_BIN="${WINETRICKS_BIN:-}"
if [[ -z "$WINETRICKS_BIN" ]]; then
  for candidate in \\
    "$APP_SUPPORT/cache/winetricks/winetricks" \\
    /opt/homebrew/bin/winetricks \\
    /usr/local/bin/winetricks; do
    if [[ -x "$candidate" ]]; then
      WINETRICKS_BIN="$candidate"
      break
    fi
  done
fi
if [[ -z "$WINETRICKS_BIN" ]]; then
  candidate="$(command -v winetricks 2>/dev/null || true)"
  if [[ -n "$candidate" && "$candidate" != "$0" ]]; then
    WINETRICKS_BIN="$candidate"
  fi
fi
if [[ -z "$WINETRICKS_BIN" || ! -x "$WINETRICKS_BIN" ]]; then
  echo "error: winetricks not found; install it or set WINETRICKS_BIN to its executable path" >&2
  exit 1
fi

WRAP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gamma-winetricks.XXXXXX")"
cleanup() {
  rm -rf "$WRAP_DIR"
}
trap cleanup EXIT

cat > "$WRAP_DIR/wine-wrapper" << 'WRAPPER_EOF'
#!/usr/bin/env bash
set -euo pipefail
binary="$(basename "$0")"
if [[ "$binary" == "wine64" && ! -x "$GAMMA_WINETRICKS_ENGINE/bin/wine64" ]]; then
  binary=wine
fi
exec arch -x86_64 "$GAMMA_WINETRICKS_ENGINE/bin/$binary" "$@"
WRAPPER_EOF
chmod +x "$WRAP_DIR/wine-wrapper"
ln -s wine-wrapper "$WRAP_DIR/wine"
ln -s wine-wrapper "$WRAP_DIR/wine64"
ln -s wine-wrapper "$WRAP_DIR/wineserver"

export GAMMA_WINETRICKS_ENGINE="$ENGINE_DIR"
export WINE="$WRAP_DIR/wine"
export WINE64="$WRAP_DIR/wine64"
export WINESERVER="$WRAP_DIR/wineserver"
export WINELOADER="$WRAP_DIR/wine"
export W_CACHE="$APP_SUPPORT/cache/winetricks/downloads"
export PATH="$WRAP_DIR:$PATH"

echo "engine:     $ENGINE_DIR"
echo "prefix:     $WINEPREFIX"
echo "winetricks: $WINETRICKS_BIN $*"
echo

status=0
"$WINETRICKS_BIN" "$@" || status=$?
exit "$status"
"""

_WINECFG_LAUNCHER_TEMPLATE = """#!/usr/bin/env bash
# Opens winecfg for this app's prefix with its bundled Wine engine.
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE_DIR="$APP_DIR/Contents/Resources/engine"
APP_SUPPORT="@@APP_SUPPORT@@"
CONFIG_FILE="$APP_SUPPORT/app.env"
export WINEPREFIX="@@WINEPREFIX@@"

if [[ ! -x "$ENGINE_DIR/bin/wine" || ! -f "$ENGINE_DIR/lib/wine/x86_64-windows/winecfg.exe" ]]; then
  echo "error: bundled Wine engine has no winecfg: $ENGINE_DIR" >&2
  exit 1
fi

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi
export GAMMA_GRAPHICS_BACKEND="${GAMMA_GRAPHICS_BACKEND:-dxmt}"

echo "engine: $ENGINE_DIR"
echo "prefix: $WINEPREFIX"
echo

exec arch -x86_64 "$ENGINE_DIR/bin/wine" \\
  "$ENGINE_DIR/lib/wine/x86_64-windows/winecfg.exe" "$@"
"""


def render_template(template: str, **tokens: str) -> str:
    rendered = template
    for key, value in tokens.items():
        rendered = rendered.replace(f"@@{key}@@", str(value))
    return rendered


# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------

def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Builds a macOS .app around the packaged GAMMA Wine engine.",
    )
    parser.add_argument("--dxmt-only", action="store_true",
                         help="Skip the backend/dependency-mode prompts; use dxmt + redist.")
    parser.add_argument("--json", action="store_true",
                         help="Emit newline-delimited JSON progress events instead of plain text.")
    parser.add_argument("--yes", action="store_true",
                         help="Auto-confirm the final summary (equivalent to answering Y).")
    parser.add_argument("--force-exe", action="store_true",
                         help="Skip the game-exe existence check (equivalent to answering y).")
    parser.add_argument("--skip-finder-alias", action="store_true",
                         help="Don't create the '<App> Configurator' Finder alias.")
    parser.add_argument("--archive", help="Path to the engine archive (.tar.zst or .tar.xz).")
    parser.add_argument("--app-name", help="Name for the .app bundle (without .app).")
    parser.add_argument("--app-parent", help="Directory to place the .app in.")
    parser.add_argument("--gamma-root", help="Path to game root (G: drive).")
    parser.add_argument("--exe-rel-path", help="Path to the .exe, relative to game root.")
    parser.add_argument("--backend", choices=["dxmt", "d3dmetal"], help="Graphics backend.")
    parser.add_argument("--runtime-mode", choices=["redist", "verbs"], help="Runtime dependency source.")
    return parser


def default_artifact_path() -> str:
    artifacts_dir = REPO_ROOT / "dist/artifacts"
    candidates = list(artifacts_dir.glob("*.tar.zst")) + list(artifacts_dir.glob("*.tar.xz"))
    if not candidates:
        return str(artifacts_dir / "engine.tar.zst")
    return str(max(candidates, key=lambda p: p.stat().st_mtime))


def symlink_force(link: Path, target) -> None:
    # CrossOver's own `wineboot -u` pre-creates a real (non-symlink)
    # drive_c/users/crossover directory as part of its default profile
    # bootstrap — Path.unlink() can't remove a directory (raises
    # PermissionError on macOS for a non-root process), so that case needs
    # shutil.rmtree instead. Check is_symlink() first: a symlink pointing
    # at a directory also satisfies is_dir(), and must be unlinked (not
    # have its target deleted).
    if link.is_symlink():
        link.unlink()
    elif link.is_dir():
        shutil.rmtree(link)
    elif link.exists():
        link.unlink()
    link.symlink_to(target)


def run_setup(args: argparse.Namespace) -> None:
    log("==========================================================")
    log("GAMMA Wine Engine — Interactive Setup")
    log("==========================================================")

    # 1. Collect paths
    default_artifact = default_artifact_path()
    while True:
        artifact_str = prompt("Path to engine archive (.tar.zst or .tar.xz)", default_artifact, args.archive)
        artifact_path = Path(artifact_str).expanduser()
        if artifact_path.is_file():
            break
        if args.archive is not None:
            raise SetupError(f"Not found: {artifact_path}")
        log(f"  Not found: {artifact_path}")

    app_name = prompt("Name for the .app bundle (without .app)", "GAMMA", args.app_name)
    if app_name.endswith(".app"):
        app_name = app_name[: -len(".app")]

    app_parent = Path(prompt("Directory to place the .app in", str(Path.home() / "Applications"),
                              args.app_parent)).expanduser()
    app_path = app_parent / f"{app_name}.app"
    if app_path.exists():
        raise SetupError(
            f"{app_path} already exists. This script never overwrites an existing wrapper "
            f"(it would corrupt that app's Wine prefix). Choose a different name, or remove "
            f"the existing .app and its ~/Library/Application Support/{app_name}/ first."
        )

    gamma_root = Path(prompt("Path to game root (G: drive)", str(Path.home() / "gamma"),
                              args.gamma_root)).expanduser()

    while True:
        exe_rel_path = prompt("Path to .exe, relative to game root", "sept/bin/AnomalyDX11.exe",
                               args.exe_rel_path).lstrip("/")
        if (gamma_root / exe_rel_path).is_file():
            break
        log(f"  Not found: {gamma_root / exe_rel_path}")
        if args.force_exe:
            break
        if args.exe_rel_path is not None:
            raise SetupError(f"Not found: {gamma_root / exe_rel_path} (pass --force-exe to use it anyway)")
        if not confirm_yes_no("  Use anyway?", default_yes=False):
            continue
        break
    exe_win_path = "G:\\" + exe_rel_path.replace("/", "\\")
    exe_rel_dir = str(Path(exe_rel_path).parent)
    exe_run_dir = gamma_root / exe_rel_dir

    if args.dxmt_only:
        graphics_backend = "dxmt"
    else:
        log("")
        log("Graphics backend:")
        log("  1) dxmt      DXMT — D3D11/10 via Metal (default, works for 32-bit too)")
        log("  2) d3dmetal  Apple D3DMetal — D3D11/12 via Metal (64-bit only)")
        choice = prompt("Select backend", "1", args.backend)
        graphics_backend = {"1": "dxmt", "dxmt": "dxmt", "2": "d3dmetal", "d3dmetal": "d3dmetal"}.get(choice)
        if graphics_backend is None:
            log(f"  Unrecognized choice '{choice}', using dxmt")
            graphics_backend = "dxmt"

    if args.dxmt_only:
        runtime_mode = "redist"
    else:
        log("")
        log("Runtime dependencies:")
        log("  1) redist  Copy bundled DLLs and register fallback overrides (default)")
        log("  2) verbs   Install required components with winetricks")
        choice = prompt("Select dependency source", "1", args.runtime_mode)
        runtime_mode = {
            "1": "redist", "redist": "redist", "dlls": "redist",
            "2": "verbs", "verbs": "verbs", "winetricks": "verbs",
        }.get(choice)
        if runtime_mode is None:
            log(f"  Unrecognized choice '{choice}', using redist")
            runtime_mode = "redist"

    retina_mode = "N"

    # cxcompatdb checks this on every wine invocation from here on (wineboot,
    # reg add/query, winecfg — not just the final generated game launcher,
    # whose own app.env-sourced export only takes effect after this exits).
    # Without it, cxcompatdb falls back to its own default (d3dmetal), which
    # fails outright against a --dxmt-only engine artifact that has no
    # lib64/apple_gptk payload at all.
    os.environ["GAMMA_GRAPHICS_BACKEND"] = graphics_backend

    app_support = Path.home() / "Library/Application Support" / app_name
    wineprefix = app_support / "prefix"
    engine_dir = app_path / "Contents/Resources/engine"
    config_file = app_support / "app.env"
    state_file = app_support / "configurator-state.json"

    log("")
    log(f"  Engine archive: {artifact_path}")
    log(f"  App bundle:     {app_path}")
    log(f"  Engine (in app):{engine_dir}")
    log(f"  Prefix:         {wineprefix}")
    log(f"  Settings:       {config_file}")
    log(f"  Game root:      {gamma_root}")
    log(f"  Backend:        {graphics_backend}")
    log(f"  Dependencies:   {runtime_mode}")
    log("")
    if not args.yes:
        if not confirm_yes_no("Proceed?", default_yes=True):
            raise SetupError("Aborted.")

    wine_env = {"WINEPREFIX": str(wineprefix)}

    # 2. Create app skeleton, extract engine
    stage_started("engine", "Step 1: Extracting Wine engine into app bundle...")
    (app_path / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
    (app_path / "Contents/Resources").mkdir(parents=True, exist_ok=True)
    engine_dir.mkdir(parents=True, exist_ok=True)
    app_support.mkdir(parents=True, exist_ok=True)
    shutil.copy2(SCRIPT_DIR / "Anomaly.icns", app_path / "Contents/Resources/Anomaly.icns")

    extract_archive(artifact_path, engine_dir)

    wine_bin = engine_dir / "bin/wine"
    if not os.access(wine_bin, os.X_OK):
        raise SetupError(f"wine binary missing after extraction at {wine_bin}")
    run(x64(str(wine_bin), "--version"))

    cxcompatdb = engine_dir / "lib/wine/x86_64-unix/cxcompatdb.so"
    if not cxcompatdb.is_file():
        raise SetupError("engine artifact has no cxcompatdb.so")

    engine_version = "1.0.0"
    version_file = engine_dir / "version"
    if version_file.is_file():
        first_line = version_file.read_text().splitlines()
        if first_line and first_line[0].strip():
            engine_version = first_line[0].strip()

    if graphics_backend == "d3dmetal":
        if not (engine_dir / "lib64/apple_gptk/wine").is_dir():
            raise SetupError("engine has no lib64/apple_gptk/wine")
    else:
        if not (engine_dir / "lib/dxmt").is_dir():
            raise SetupError("engine has no lib/dxmt")
    stage_finished("engine")

    # 3. Bootstrap prefix (outside the bundle)
    stage_started("prefix", "Step 2: Bootstrapping Wine prefix...")
    run(wineserver_cmd(engine_dir, "-k"), env=wine_env, check=False, quiet=True)
    wineprefix.mkdir(parents=True, exist_ok=True)
    run(wine_cmd(engine_dir, "wineboot", "-u"), env=wine_env)
    run(wineserver_cmd(engine_dir, "-w"), env=wine_env)
    stage_finished("prefix")

    stage_started("driveMapping", "Step 2.2: Drive mappings & user profile...")
    dosdevices = wineprefix / "dosdevices"
    dosdevices.mkdir(parents=True, exist_ok=True)
    symlink_force(dosdevices / "z:", "/")
    symlink_force(dosdevices / "c:", "../drive_c")
    symlink_force(dosdevices / "g:", gamma_root)

    # wineboot -u (just above) already creates a REAL, fully-initialized
    # Windows profile at drive_c/users/crossover — Desktop, Documents,
    # AppData/Local/Temp, AppData/Local/ModOrganizer, all of it. The
    # previous direction here (symlink crossover -> a freshly-mkdir'd,
    # near-empty "Sikarugir") deleted that real profile and replaced apps
    # running as "crossover" with a stub missing AppData/Local/Temp —
    # which broke MO2's own atomic modlist.txt save ("could not create a
    # temporary file"). Point the aliases AT the real profile instead of
    # replacing it. Guard against a stale symlink left by that old
    # behavior (a prefix from an earlier broken run): if crossover is
    # already a symlink, drop it and let a real directory take its place.
    real_profile = wineprefix / "drive_c/users/crossover"
    if real_profile.is_symlink():
        real_profile.unlink()
    if not real_profile.exists():
        real_profile.mkdir(parents=True, exist_ok=True)
    symlink_force(wineprefix / "drive_c/users/Sikarugir", "crossover")
    symlink_force(wineprefix / "drive_c/users" / os.environ.get("USER", "user"), "crossover")
    stage_finished("driveMapping")

    stage_started("prefix", "Step 2.3: Runtime settings...")

    queue_reg(r"HKEY_CURRENT_USER\Software\Wine\Drivers", "Graphics", "REG_SZ", "mac")
    queue_reg(r"HKEY_CURRENT_USER\Software\Wine\Mac Driver", "AllowSetGamma", "REG_DWORD", "0")
    queue_reg(r"HKEY_CURRENT_USER\Software\Wine\Mac Driver", "RetinaMode", "REG_SZ", retina_mode)

    # Renderer DLLs deliberately get no registry overrides here. cxcompatdb
    # selects their backend directory before Wine resolves those modules.
    queue_reg(r"HKEY_CURRENT_USER\Software\Wine\DllOverrides", "winemenubuilder.exe", "REG_SZ", "")

    # d3d10 gets a per-app (not global) override, scoped to the game's own
    # exe: GPTK's own d3d10.dll (always present in the staged payload) trips
    # a save-game hang (see docs/renderers.md); this pins d3d10 at Wine's
    # own genuine, independent implementation instead of leaving resolution
    # to chance. Applies to D3DMetal. The game never calls
    # D3D10CreateDevice; D3DX11's internal D3D10CreateBlob dependency only
    # needs Wine's implementation to resolve.
    if graphics_backend == "d3dmetal":
        exe_basename = Path(exe_rel_path).name
        queue_reg(
            f"HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\{exe_basename}\\DllOverrides",
            "d3d10", "REG_SZ", "builtin",
        )
        log(f"  Added d3d10=builtin override for {exe_basename}")
    stage_finished("prefix")

    if runtime_mode == "verbs":
        stage_started("winetricks", "Step 2.4: Installing DirectX/VC++ components with winetricks...")
        winetricks_bin = resolve_winetricks(app_support)
        if not winetricks_bin:
            raise SetupError("winetricks unavailable. Re-run setup and select redist fallback.")
        (app_support / "cache/winetricks/downloads").mkdir(parents=True, exist_ok=True)
        run_winetricks_now(
            winetricks_bin, engine_dir, wineprefix, app_support,
            ["-q", "d3dx9_43", "d3dx11_43", "d3dcompiler_43", "d3dcompiler_47", "vcrun2022", "win10", "sound=coreaudio"],
        )
        missing_overrides = []
        for dll in ("d3dx9_43", "d3dx11_43", "d3dcompiler_43", "d3dcompiler_47", "concrt140", "msvcp140", "vcruntime140"):
            returncode, _ = run(
                wine_cmd(engine_dir, "reg", "query", r"HKEY_CURRENT_USER\Software\Wine\DllOverrides", "/v", f"*{dll}"),
                env=wine_env, check=False, quiet=True,
            )
            if returncode != 0:
                err(f"Error: winetricks did not register expected override: *{dll}")
                missing_overrides.append(dll)
        if missing_overrides:
            raise SetupError(
                "verbs installation completed without its required overrides. "
                "Use redist fallback only if you explicitly want the fallback policy."
            )
    else:
        stage_started("winetricks", "Step 2.4: Installing bundled DirectX/VC++ redistributables...")
        redist_dir = engine_dir / "share/gamma/redist"
        if not redist_dir.is_dir():
            redist_dir = engine_dir / "redist"
        if not redist_dir.is_dir():
            redist_dir = REPO_ROOT / "runtime/redist"
        sys64 = wineprefix / "drive_c/windows/system32"
        # 64-bit only: the redist payload is grouped one subdirectory per
        # package (d3dcompiler_47/, directx_Jun2010_redist/, vcrun2022/,
        # ...), each holding an x86_64-windows/*.dll set confirmed required
        # against xray-monolith.
        redist_dlls = sorted(redist_dir.glob("*/x86_64-windows/*.dll"))
        if not redist_dlls:
            raise SetupError("bundled redist payload is missing")
        sys64.mkdir(parents=True, exist_ok=True)
        for dll in redist_dlls:
            shutil.copy2(dll, sys64 / dll.name)
        for dll in redist_dlls:
            queue_reg(r"HKEY_CURRENT_USER\Software\Wine\DllOverrides", f"*{dll.stem}", "REG_SZ", "native,builtin")
        # Not `winecfg.exe -v win10`: winecfg has no headless "set and
        # exit" mode — it always opens its GUI window and blocks
        # indefinitely waiting for someone to close it, hanging any
        # automated/unattended run. This registry write is exactly what
        # that flag does internally (winecfg's own Windows-Version setting
        # is just HKEY_CURRENT_USER\Software\Wine\Version).
        queue_reg(r"HKEY_CURRENT_USER\Software\Wine", "Version", "REG_SZ", "win10")
        queue_reg(r"HKEY_CURRENT_USER\Software\Wine\Drivers", "Audio", "REG_SZ", "coreaudio")

    flush_reg_queue(engine_dir, wineprefix)
    run(wineserver_cmd(engine_dir, "-w"), env=wine_env)
    stage_finished("winetricks")

    # 4. Bundle metadata, settings file, launcher
    stage_started("wrapper", "Step 3: Writing .app bundle metadata & launcher...")

    bundle_id_suffix = app_name.lower().replace(" ", "-")
    info_plist = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>CFBundleDevelopmentRegion</key>
\t<string>English</string>
\t<key>CFBundleDisplayName</key>
\t<string>{app_name}</string>
\t<key>CFBundleExecutable</key>
\t<string>launcher</string>
\t<key>CFBundleIconFile</key>
\t<string>Anomaly.icns</string>
\t<key>CFBundleIdentifier</key>
\t<string>com.gamma.wine-engine.{bundle_id_suffix}</string>
\t<key>CFBundleInfoDictionaryVersion</key>
\t<string>1.0</string>
\t<key>CFBundleName</key>
\t<string>{app_name}</string>
\t<key>CFBundlePackageType</key>
\t<string>APPL</string>
\t<key>CFBundleShortVersionString</key>
\t<string>{engine_version}</string>
\t<key>CFBundleVersion</key>
\t<string>{engine_version}</string>
\t<key>LSMinimumSystemVersion</key>
\t<string>10.15</string>
\t<key>NSHighResolutionCapable</key>
\t<true/>
\t<key>NSSupportsAutomaticGraphicsSwitching</key>
\t<true/>
\t<key>NSPrincipalClass</key>
\t<string>NSApplication</string>
</dict>
</plist>
"""
    (app_path / "Contents/Info.plist").write_text(info_plist)

    # Settings live outside the bundle: editing them must not break the
    # signature. Minimal, backend-conditional seed — only the always-on
    # vars for the chosen backend; every optional/untested var stays absent
    # (Configurator's default = disabled). No inline comments: Configurator
    # is the documented interface now (runtime/configurator/configurator.py's
    # SCHEMA), this file is generated output. Keep this seed's var
    # names/quoting in sync with that SCHEMA by hand — there is no automated
    # check.
    if config_file.is_file():
        log(f"  Keeping existing settings: {config_file}")
    else:
        lines = [
            "# Edit via Contents/MacOS/configurator — see it for descriptions and valid ranges.",
            "",
            f"export GAMMA_GRAPHICS_BACKEND={graphics_backend}",
            f"export EXE_PATH='{exe_win_path}'",
            f"export EXE_RUN_DIR='{exe_run_dir}'",
            "",
            "export MTL_HUD_ENABLED=0",
            "export WINEMSYNC=1",
            "export WINEESYNC=1",
            "export ROSETTA_ADVERTISE_AVX=0",
            'export WINEDEBUG="-all"',
            'export DEFAULT_GAME_ARGS=""',
            f"export GAMMA_RETINA_MODE={retina_mode}",
            "",
        ]
        if graphics_backend == "d3dmetal":
            lines += [
                "export D3DM_ENABLE_METALFX=0",
                "export D3DM_MAX_FPS=60",
                "export D3DM_POSITION_INVARIANCE=1",
                "export D3DM_SAMPLE_NAN_TO_ZERO=1",
                "export D3DM_FLUSH_POS_INF_TO_NAN=1",
            ]
        else:
            lines += [
                "export DXMT_METALFX_SPATIAL_SWAPCHAIN=0",
                "export DXMT_ENABLE_NVEXT=0",
            ]
        config_file.write_text("\n".join(lines) + "\n")
        log(f"  Wrote settings: {config_file}")

    launcher_path = app_path / "Contents/MacOS/launcher"
    launcher_path.write_text(render_template(
        _LAUNCHER_TEMPLATE,
        APP_SUPPORT=app_support, GRAPHICS_BACKEND=graphics_backend,
        EXE_WIN_PATH=exe_win_path, EXE_RUN_DIR=exe_run_dir,
    ))

    winetricks_path = app_path / "Contents/MacOS/winetricks"
    winetricks_path.write_text(render_template(
        _WINETRICKS_LAUNCHER_TEMPLATE, APP_SUPPORT=app_support, WINEPREFIX=wineprefix,
    ))

    winecfg_path = app_path / "Contents/MacOS/winecfg"
    winecfg_path.write_text(render_template(
        _WINECFG_LAUNCHER_TEMPLATE, APP_SUPPORT=app_support, WINEPREFIX=wineprefix,
    ))

    # Native SwiftUI GUI over app.env: renders the schema (Schema.swift,
    # ported from the former runtime/configurator/configurator.py) as
    # toggles/fields grouped by section, keyed off a sidecar
    # configurator-state.json (holds every var's value + enabled state
    # regardless of current backend, so switching backends or re-enabling a
    # var restores exactly what was typed before). app.env itself is pure
    # generated output — no inline comments, no lines for the backend
    # that isn't selected. Built by pack-engine-artifact.sh
    # (scripts/build-configurator.sh) and shipped prebuilt inside the
    # engine artifact (share/gamma/Configurator.app) — this script stays
    # standalone/archive-only and never builds anything from source. It's a
    # real nested .app bundle (not a loose binary) so it opens as a GUI
    # window, not Terminal, when launched directly or via the "<app name>
    # Configurator" alias (named to sort next to the main .app in Finder).
    configurator_src = engine_dir / "share/gamma/Configurator.app"
    if not configurator_src.is_dir():
        raise SetupError("Configurator.app is missing (expected in the engine artifact)")
    configurator_dst = app_path / "Contents/Resources/Configurator.app"
    shutil.copytree(configurator_src, configurator_dst)
    configurator_resources = configurator_dst / "Contents/Resources"
    configurator_resources.mkdir(parents=True, exist_ok=True)
    (configurator_resources / "paths.json").write_text(json.dumps({
        "configFile": str(config_file),
        "stateFile": str(state_file),
        "dxmtOnly": bool(args.dxmt_only),
    }))

    for path in (launcher_path, winetricks_path, winecfg_path):
        os.chmod(path, 0o755)
    stage_finished("wrapper")

    # 5. Ad-hoc sign the bundle. The engine payload (and the
    #    Configurator.app nested inside it) is already signed by
    #    pack-engine-artifact.sh; this re-signs the wrapper scripts plus the
    #    whole bundle envelope so the paths.json we just dropped in doesn't
    #    invalidate anything upstream.
    stage_started("finalize", "Step 4: Signing bundle...")

    def codesign_soft(target: Path) -> bool:
        returncode, _ = run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(target)],
                             check=False, quiet=True)
        return returncode == 0

    codesign_soft(launcher_path)
    codesign_soft(winetricks_path)
    codesign_soft(winecfg_path)
    codesign_soft(configurator_dst)
    if codesign_soft(app_path):
        log(f"  Ad-hoc signed {app_path}")
    else:
        err("  Warning: could not sign the bundle (it will still run locally)")

    log("Step 5: Registering with Launch Services...")
    run(
        ["/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
         "-f", str(app_path)],
        check=False, quiet=True,
    )

    alias_name = f"{app_name} Configurator"
    alias_path = app_parent / f"{alias_name}.app"
    log(f'Step 6: Creating "{alias_name}" alias...')
    if args.skip_finder_alias:
        log("  Skipping Finder alias creation (--skip-finder-alias)")
    elif alias_path.exists():
        log(f"  Skipping: {alias_path} already exists")
    else:
        # Guarded, unlike the rest of this script's happy path: this is the
        # one step that can fail for an environment reason outside our
        # control (the calling process lacking Automation/Apple-Events
        # permission to Finder), after the app bundle and Wine prefix
        # already exist — a failure here must not abort or misrepresent an
        # otherwise-successful setup.
        osa_script = (
            'tell application "Finder"\n'
            f'  set aliasFile to make new alias file at POSIX file "{app_parent}" '
            f'to (POSIX file "{configurator_dst}" as alias)\n'
            f'  set name of aliasFile to "{alias_name}"\n'
            "end tell"
        )
        returncode, output = run(["osascript", "-e", osa_script], check=False, quiet=True)
        if returncode != 0:
            err(f"  Warning: could not create Finder alias (Automation/Apple Events permission?): {output}")

    artifact_event(app_path)

    log("")
    log("==========================================================")
    log("Setup complete.")
    log(f"  App:      {app_path}")
    log(f"  Engine:   {engine_dir}  (inside app, read-only)")
    log(f"  Prefix:   {wineprefix}")
    log(f"  Settings: {config_file}")
    log(f"  Backend:  {graphics_backend}  (change it in app.env, no rebuild needed)")
    log(f"  Dependencies: {runtime_mode}")
    if graphics_backend == "d3dmetal":
        log("  GPTK:     staged by install-renderers.sh (--apple-gptk selects the version)")
        log(f"            d3d10=builtin override added for {Path(exe_rel_path).name}")
    log("")
    log(f'Launch via:  open "{app_path}"')
    log(f'Or CLI:      "{app_path}/Contents/MacOS/launcher" -dbg -nointro')
    log(f'Winetricks:  "{app_path}/Contents/MacOS/winetricks" [verb ...]')
    log(f'WineCfg:     "{app_path}/Contents/MacOS/winecfg"')
    log(f'Configurator: double-click "{alias_name}" next to the app in {app_parent}')
    log(f'              or open "{configurator_dst}"')
    log("==========================================================")
    stage_finished("finalize")


def main() -> None:
    global JSON_MODE
    parser = build_arg_parser()
    args = parser.parse_args()
    JSON_MODE = args.json
    try:
        run_setup(args)
    except SetupError as exc:
        if _CURRENT_STAGE:
            stage_failed(_CURRENT_STAGE, str(exc))
        completed(False, str(exc))
        err(f"error: {exc}")
        sys.exit(1)
    except KeyboardInterrupt:
        completed(False, "Interrupted")
        sys.exit(130)
    else:
        completed(True, "Setup complete.")


if __name__ == "__main__":
    main()
