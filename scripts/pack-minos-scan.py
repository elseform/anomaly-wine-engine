#!/usr/bin/env python3
"""Scan a staged engine tree for Mach-O `minos` violations.

The product host minOS floor is 10.15. The single narrow exception is
upstream DXMT's bundled `winemetal.so` (and any other Mach-O under
`lib/dxmt/**`): pinned upstream v0.80 declares minos up to 15.0, and Cyder
only offers DXMT as a selectable graphics backend on macOS 15+, so this
exemption cannot regress the floor for any other shipped binary
(`wine`, `wineserver`, `*.so`, bundled dylibs).

Apple GPTK/D3DMetal is staged once using CrossOver's native
`lib64/apple_gptk/**` layout.

`share/gamma/Configurator.app/**` is a separate, standalone SwiftUI helper
app (not loaded into the Wine process, not game-critical) launched directly
by the user — its own Info.plist `LSMinimumSystemVersion` is what gates its
minimum OS, not this engine-payload floor, so it's exempt the same way.
"""
import re
import subprocess
import sys
from pathlib import Path

DXMT_PATH_PREFIX = "lib/dxmt/"
D3DMETAL_PATH_PREFIX = "lib64/apple_gptk/"
CONFIGURATOR_PATH_PREFIX = "share/gamma/Configurator.app/"
DXMT_MINOS_CEILING = (99, 0, 0)


def parse_version(v: str):
    parts = [int(x) for x in v.split(".")]
    while len(parts) < 3:
        parts.append(0)
    return tuple(parts[:3])


def is_renderer_exempt_path(rel_path: str) -> bool:
    """True when rel_path (posix-style, relative to the engine root) is
    bundled upstream DXMT or Apple GPTK/D3DMetal payload."""
    return (
        rel_path.startswith(DXMT_PATH_PREFIX)
        or rel_path.startswith(D3DMETAL_PATH_PREFIX)
        or rel_path.startswith(CONFIGURATOR_PATH_PREFIX)
    )


def minos_limit_for(rel_path: str, floor: tuple) -> tuple:
    """Effective minos ceiling for rel_path: the product floor everywhere,
    except bundled renderers (DXMT, D3DMetal)."""
    if is_renderer_exempt_path(rel_path):
        return max(floor, DXMT_MINOS_CEILING)
    return floor


def scan(root: Path, floor_s: str):
    floor = parse_version(floor_s)
    violations = []
    for p in root.rglob("*"):
        if not p.is_file() or p.is_symlink():
            continue
        try:
            f = subprocess.check_output(["file", "-b", str(p)], text=True, stderr=subprocess.DEVNULL)
        except Exception:
            continue
        if "Mach-O" not in f:
            continue
        out = subprocess.check_output(["otool", "-l", str(p)], text=True, stderr=subprocess.DEVNULL)
        m = re.search(r"\bminos\s+(\d+(?:\.\d+)*)", out)
        if not m:
            continue
        rel = str(p.relative_to(root))
        limit = minos_limit_for(rel, floor)
        if parse_version(m.group(1)) > limit:
            violations.append((m.group(1), rel))
    return floor, violations


def main(argv) -> int:
    if len(argv) != 3:
        print(f"Usage: {argv[0]} <engine-tree> <minos-floor>", file=sys.stderr)
        return 2
    root = Path(argv[1])
    floor_s = argv[2]
    floor, violations = scan(root, floor_s)
    ceiling_s = ".".join(str(x) for x in DXMT_MINOS_CEILING)
    if violations:
        print(
            f"Refusing to pack: Mach-O minos exceeds allowed ceiling "
            f"(product floor {floor_s}; {DXMT_PATH_PREFIX}**, "
            f"{D3DMETAL_PATH_PREFIX}**, and {CONFIGURATOR_PATH_PREFIX}** "
            f"are exempt up to {ceiling_s}):",
            file=sys.stderr,
        )
        for ver, rel in sorted(violations):
            print(f"  {ver}  {rel}", file=sys.stderr)
        return 1
    print(
        f"OK: staged engine Mach-O minos <= {floor_s} "
        f"({DXMT_PATH_PREFIX}**, {D3DMETAL_PATH_PREFIX}**, and "
        f"{CONFIGURATOR_PATH_PREFIX}** exempt up to {ceiling_s})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
