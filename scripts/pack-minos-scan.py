#!/usr/bin/env python3
"""Refuse to pack an engine that needs a newer macOS than the product supports.

Two limits apply:

- The build floor (MACOSX_DEPLOYMENT_TARGET, default 10.15) is what Wine,
  ntdll.so and the bundled dylibs are compiled for. Every Mach-O outside the
  renderer and Configurator trees must declare `minos` at or below it.
- The product floor (GAMMA_PRODUCT_MIN_OS, default 15.0) is the oldest macOS the
  engine supports: Apple Silicon, macOS 15. Renderer payloads (`lib/dxmt/`,
  `lib64/apple_gptk/`) and the Configurator (`share/gamma/Configurator.app/`)
  may target up to it, never beyond. That covers both their Mach-O `minos` and
  the Metal shader libraries DXMT embeds in its PE DLLs, whose AIR target triple
  (`air64...-apple-macosx<version>`) comes from the build Mac's OS unless the
  build pins MACOSX_DEPLOYMENT_TARGET.
"""
import os
import re
import subprocess
import sys
from pathlib import Path

RENDERER_PATH_PREFIXES = ("lib/dxmt/", "lib64/apple_gptk/", "share/gamma/Configurator.app/")
AIR_TARGET = re.compile(rb"apple-macosx(\d+(?:\.\d+)*)")


def parse_version(v: str):
    parts = [int(x) for x in v.split(".")]
    while len(parts) < 3:
        parts.append(0)
    return tuple(parts[:3])


def limit_for(rel_path: str, build_floor: tuple, product_floor: tuple) -> tuple:
    if rel_path.startswith(RENDERER_PATH_PREFIXES):
        return product_floor
    return build_floor


def scan(root: Path, build_floor: tuple, product_floor: tuple):
    violations = []
    for p in root.rglob("*"):
        if not p.is_file() or p.is_symlink():
            continue
        rel = p.relative_to(root).as_posix()
        try:
            kind = subprocess.check_output(["file", "-b", str(p)], text=True, stderr=subprocess.DEVNULL)
        except Exception:
            continue
        if "Mach-O" in kind:
            out = subprocess.check_output(["otool", "-l", str(p)], text=True, stderr=subprocess.DEVNULL)
            m = re.search(r"\bminos\s+(\d+(?:\.\d+)*)", out)
            if m and parse_version(m.group(1)) > limit_for(rel, build_floor, product_floor):
                violations.append((m.group(1), rel, "minos"))
        elif rel.startswith("lib/dxmt/") and "PE32" in kind:
            for version in sorted({v.decode() for v in AIR_TARGET.findall(p.read_bytes())}):
                if parse_version(version) > product_floor:
                    violations.append((version, rel, "Metal shader target"))
    return violations


def main(argv) -> int:
    if len(argv) not in (3, 4):
        print(f"Usage: {argv[0]} <engine-tree> <build-floor> [<product-floor>]", file=sys.stderr)
        return 2
    root = Path(argv[1])
    build_floor_s = argv[2]
    product_floor_s = argv[3] if len(argv) == 4 else os.environ.get("GAMMA_PRODUCT_MIN_OS", "15.0")
    violations = scan(root, parse_version(build_floor_s), parse_version(product_floor_s))
    if violations:
        print(
            f"Refusing to pack: binaries need a newer macOS than allowed "
            f"(build floor {build_floor_s}; renderers and Configurator up to "
            f"the product floor {product_floor_s}):",
            file=sys.stderr,
        )
        for ver, rel, what in sorted(violations):
            print(f"  {ver}  {rel}  ({what})", file=sys.stderr)
        return 1
    print(
        f"OK: Mach-O minos <= {build_floor_s}; renderers, Configurator and DXMT "
        f"Metal shaders <= {product_floor_s}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
