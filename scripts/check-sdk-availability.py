#!/usr/bin/env python3
"""Refuse a Wine configuration that uses C library functions newer than the product floor.

Wine's configure detects functions by linking a stub against the SDK, so it
enables anything the build Mac's SDK exports, however new. The engine is
compiled for an older deployment target, so such a function is weak-linked and
resolves to NULL on an older macOS: Wine crashes the first time it calls it.
Example: the macOS 27 SDK added pipe2(), which ntdll uses when HAVE_PIPE2 is
defined.

For every HAVE_<NAME> that config.h defines and whose lower-case <name> is
declared as a function in the SDK's usr/include, this compiles a reference to
it with -mmacosx-version-min set to the product floor and
-Werror=unguarded-availability. A function the SDK marks as newer than the
floor is reported, and the script exits non-zero. Fix it by pinning the
configure cache variable (ac_cv_func_<name>=no) in build-wine.sh.

Framework functions (outside usr/include) are not checked.

  check-sdk-availability.py <build64/include/config.h> <product-floor>
"""
import re
import subprocess
import sys
from pathlib import Path

HAVE_DEFINE = re.compile(r"^#define HAVE_([A-Z0-9_]+) 1$", re.M)
UNAVAILABLE = re.compile(r"'(\w+)' is only available on macOS ([0-9.]+) or newer")


def sdk_include() -> Path:
    sdk = subprocess.run(["xcrun", "--show-sdk-path"], check=True, capture_output=True, text=True)
    return Path(sdk.stdout.strip()) / "usr" / "include"


def declaring_headers(include: Path, names: set) -> dict:
    """Map each name to the headers (relative to usr/include) that declare it as a function."""
    pattern = re.compile(r"\b(" + "|".join(sorted(names)) + r")\s*\(")
    found = {}
    for header in sorted(include.rglob("*.h")):
        try:
            text = header.read_text(errors="replace")
        except OSError:
            continue
        for name in set(pattern.findall(text)):
            found.setdefault(name, []).append(header.relative_to(include).as_posix())
    return found


def check(name: str, headers: list, floor: str):
    """Return (introduced-version or None, checked?)."""
    for header in headers:
        source = f"#include <sys/types.h>\n#include <{header}>\nvoid *anomaly_ref = (void *)&{name};\n"
        result = subprocess.run(
            ["xcrun", "clang", "-arch", "x86_64", "-fsyntax-only", f"-mmacosx-version-min={floor}",
             "-Werror=unguarded-availability", "-x", "c", "-"],
            input=source, capture_output=True, text=True,
        )
        if result.returncode == 0:
            return None, True
        match = UNAVAILABLE.search(result.stderr)
        if match and match.group(1) == name:
            return match.group(2), True
    return None, False


def main(argv) -> int:
    if len(argv) != 3:
        print(f"Usage: {argv[0]} <config.h> <product-floor>", file=sys.stderr)
        return 2
    config_h, floor = Path(argv[1]), argv[2]
    names = {m.lower() for m in HAVE_DEFINE.findall(config_h.read_text())}
    headers = declaring_headers(sdk_include(), names)

    too_new, unchecked = [], []
    for name in sorted(headers):
        introduced, checked = check(name, headers[name], floor)
        if introduced:
            too_new.append((name, introduced))
        elif not checked:
            unchecked.append(name)

    if unchecked:
        print(f"Could not check (no header compiled on its own): {' '.join(unchecked)}")
    if too_new:
        print(f"{config_h} enables functions newer than the product floor (macOS {floor}):", file=sys.stderr)
        for name, introduced in too_new:
            print(f"  {name}  (macOS {introduced})  pin ac_cv_func_{name}=no in build-wine.sh", file=sys.stderr)
        return 1
    print(f"OK: {len(headers) - len(unchecked)} C library functions in config.h are available on macOS {floor}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
