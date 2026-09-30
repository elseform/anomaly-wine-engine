#!/usr/bin/env python3
"""Regenerate config/redist-manifest.json from the pinned public installers.

The manifest is what lets the engine stop shipping Microsoft's redistributable
DLLs: it records, for every DLL the engine needs, which public installer
carries it, where inside that installer it lives, and what its SHA-256 is.
`runtime/redist-fetch/anomaly_redist.py` consumes it at wrapper-setup time.

This script discovers the member paths rather than trusting a hand-written
list: it walks each installer's cabinets, matches members by filename, and
records the SHA-256 it actually read. It then cross-checks the result against
the local reference set under runtime/redist/ (kept out of git, archived in
gamma-wip) and prints any file whose bytes differ, so a substitution can never
happen silently.

Usage:
  scripts/write-redist-manifest.py [--installer-dir DIR] [--check]

  --installer-dir  Look for already-downloaded installers here before
                   fetching. Repeatable.
  --check          Verify the committed manifest still matches the installers
                   and exit non-zero on drift, without rewriting anything.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "runtime/redist-fetch"))

import anomaly_redist  # noqa: E402

MANIFEST_PATH = REPO_ROOT / "config/redist-manifest.json"
REFERENCE_DIR = REPO_ROOT / "runtime/redist"

# Pinned, immutable download URLs. The `aka.ms` alias for vc_redist is a
# moving target that points at whatever the current release is, so the pin is
# the versioned URL it resolved to; `alias` is recorded only so a future
# refresh knows where to look.
INSTALLERS = {
    "vc_redist_x64": {
        "url": (
            "https://download.visualstudio.microsoft.com/download/pr/"
            "bd1c8d9d-ba95-4eee-bc6e-df1fcc876373/"
            "CC0FF0EB1DC3F5188AE6300FAEF32BF5BEEBA4BDD6E8E445A9184072096B713B/"
            "VC_redist.x64.exe"
        ),
        "alias": "https://aka.ms/vs/17/release/vc_redist.x64.exe",
        "filename": "VC_redist.x64.exe",
        "sha256": "cc0ff0eb1dc3f5188ae6300faef32bf5beeba4bdd6e8e445a9184072096b713b",
        "container": "wix-burn",
        "sizeLabel": "24 MB",
        "title": "Microsoft Visual C++ 2015-2022 Redistributable (x64)",
        "publisher": "Microsoft",
    },
    "directx_jun2010_redist": {
        "url": (
            "https://download.microsoft.com/download/8/4/A/"
            "84A35BF1-DAFE-4AE8-82AF-AD2AE20B6B14/directx_Jun2010_redist.exe"
        ),
        "filename": "directx_Jun2010_redist.exe",
        "sha256": "053f76dcbb28802e23341b6a787e3b0791c0fa5c8d4d011b1044172dbf89c73b",
        "container": "cab",
        "sizeLabel": "96 MB",
        "title": "DirectX End-User Runtime (June 2010 redistributable)",
        "publisher": "Microsoft",
    },
    "fxc2_d3dcompiler_47": {
        "url": (
            "https://raw.githubusercontent.com/mozilla/fxc2/"
            "9aba9b11079303d5577e0e3eb455f4d00f3b5946/dll/d3dcompiler_47.dll"
        ),
        "filename": "d3dcompiler_47.dll",
        "sha256": "4432bbd1a390874f3f0a503d45cc48d346abc3a8c0213c289f4b615bf0ee84f3",
        "container": "raw",
        "sizeLabel": "4 MB",
        "title": "Direct3D HLSL compiler 10.0.17134.12, as redistributed by mozilla/fxc2",
        "publisher": "Microsoft, via mozilla/fxc2",
        "note": (
            "The same build winetricks' d3dcompiler_47 verb installs. Microsoft "
            "publishes no standalone redistributable for this DLL, and the "
            "6.3.9600.16384 build the engine used to bundle has no public "
            "installer at all."
        ),
    },
}

# Which DLLs come from which installer. Names are the filenames the engine
# needs in system32; the member path inside each installer is discovered.
WANTED = {
    "vc_redist_x64": [
        "concrt140.dll", "mfc140.dll", "mfc140chs.dll", "mfc140cht.dll",
        "mfc140deu.dll", "mfc140enu.dll", "mfc140esn.dll", "mfc140fra.dll",
        "mfc140ita.dll", "mfc140jpn.dll", "mfc140kor.dll", "mfc140rus.dll",
        "mfc140u.dll", "mfcm140.dll", "mfcm140u.dll", "msvcp140.dll",
        "msvcp140_1.dll", "msvcp140_2.dll", "msvcp140_atomic_wait.dll",
        "msvcp140_codecvt_ids.dll", "vcamp140.dll", "vccorlib140.dll",
        "vcomp140.dll", "vcruntime140.dll", "vcruntime140_1.dll",
        "vcruntime140_threads.dll",
    ],
    "directx_jun2010_redist": ["d3dx9_43.dll", "d3dx10_43.dll", "d3dx11_43.dll"],
    "fxc2_d3dcompiler_47": ["d3dcompiler_47.dll"],
}

# Inside vc_redist the DLLs carry an architecture suffix, and a few use
# `_system_amd64` instead. Inside the DirectX redist each DLL sits in its own
# per-component cabinet.
VC_SUFFIXES = (".dll_amd64", ".dll_system_amd64")


def _listing(archive: Path) -> list[str]:
    result = subprocess.run(
        [anomaly_redist.BSDTAR, "-tf", str(archive)],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise anomaly_redist.RedistError(f"cannot list {archive}: {result.stderr.strip()}")
    return [line for line in result.stdout.splitlines() if line]


def discover_vc(container: Path, wanted: list[str], work: Path) -> dict[str, list[str]]:
    """Map each wanted DLL to ["<payload cab>", "<member>"] inside the bundle."""
    found: dict[str, list[str]] = {}
    for cab_name in _listing(container):
        if not cab_name.startswith("a"):
            continue
        cab = anomaly_redist._extract_member(container, cab_name, work / cab_name)
        try:
            members = _listing(cab)
        except anomaly_redist.RedistError:
            continue
        for member in members:
            for suffix in VC_SUFFIXES:
                if not member.endswith(suffix):
                    continue
                target = member[: -len(suffix)] + ".dll"
                # mfcm140/mfcm140u appear in two payload cabinets; first wins.
                if target in wanted and target not in found:
                    found[target] = [cab_name, member]
    return found


def discover_directx(container: Path, wanted: list[str]) -> dict[str, list[str]]:
    found: dict[str, list[str]] = {}
    cabs = [n for n in _listing(container) if n.lower().endswith("_x64.cab")]
    for target in wanted:
        stem = target[: -len(".dll")]
        # e.g. d3dx9_43.dll -> Jun2010_d3dx9_43_x64.cab
        matches = [c for c in cabs if stem.lower() in c.lower()]
        if not matches:
            continue
        found[target] = [sorted(matches)[0], target]
    return found


def build(installer_dirs: list[Path]) -> dict:
    cache_dir = Path(tempfile.gettempdir()) / "anomaly-redist-installers"
    files: list[dict] = []

    for name, wanted in WANTED.items():
        spec = INSTALLERS[name]
        installer = anomaly_redist.resolve_installer(
            name, spec, cache_dir, installer_dirs, log=lambda m: print(f"  {m}")
        )
        print(f"==> {name}: {installer}")

        if spec["container"] == "raw":
            target = wanted[0]
            files.append({
                "target": target,
                "installer": name,
                "memberPath": [],
                "sha256": anomaly_redist._sha256(installer),
                "size": installer.stat().st_size,
            })
            continue

        with tempfile.TemporaryDirectory(prefix="anomaly-redist-gen-") as tmp:
            work = Path(tmp)
            container = anomaly_redist._container_for(installer, spec["container"], work)
            if spec["container"] == "wix-burn":
                mapping = discover_vc(container, wanted, work / "cabs")
            else:
                mapping = discover_directx(container, wanted)

            missing = sorted(set(wanted) - set(mapping))
            if missing:
                raise SystemExit(
                    f"error: {name} does not contain: {', '.join(missing)}"
                )

            for target in wanted:
                member_path = mapping[target]
                extracted = anomaly_redist._extract_path(
                    container, member_path, work / f"x-{target}"
                )
                files.append({
                    "target": target,
                    "installer": name,
                    "memberPath": member_path,
                    "sha256": anomaly_redist._sha256(extracted),
                    "size": extracted.stat().st_size,
                })

    files.sort(key=lambda entry: entry["target"])
    return {
        "schemaVersion": 1,
        "description": (
            "Microsoft redistributable DLLs the Anomaly Wine engine needs in its "
            "prefix, and the public installers they are extracted from. "
            "Regenerate with scripts/write-redist-manifest.py."
        ),
        "installers": INSTALLERS,
        "files": files,
    }


def cross_check(files: list[dict]) -> int:
    """Compare against the local reference set and report any difference."""
    if not REFERENCE_DIR.is_dir():
        print(f"note: no local reference set at {REFERENCE_DIR}, skipping cross-check")
        return 0
    reference = {
        path.name: anomaly_redist._sha256(path)
        for path in sorted(REFERENCE_DIR.glob("*/x86_64-windows/*.dll"))
        if not path.name.startswith("._")
    }
    differences = 0
    for entry in files:
        target = entry["target"]
        if target not in reference:
            print(f"  + {target}: not in the reference set")
            differences += 1
        elif reference[target] != entry["sha256"]:
            print(f"  ! {target}: differs from the reference set")
            print(f"      reference {reference[target]}")
            print(f"      installer {entry['sha256']}")
            differences += 1
    for target in sorted(set(reference) - {entry["target"] for entry in files}):
        print(f"  - {target}: in the reference set but not in the manifest")
        differences += 1
    if not differences:
        print(f"  all {len(files)} files match the reference set byte for byte")
    return differences


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--installer-dir", action="append", default=[], type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    manifest = build(args.installer_dir)

    print("\n==> Cross-check against the local reference set")
    differences = cross_check(manifest["files"])

    if args.check:
        if not MANIFEST_PATH.is_file():
            print(f"error: {MANIFEST_PATH} does not exist", file=sys.stderr)
            return 1
        committed = json.loads(MANIFEST_PATH.read_text())
        if committed != manifest:
            print(f"error: {MANIFEST_PATH} is out of date", file=sys.stderr)
            return 1
        print(f"\n{MANIFEST_PATH.name} is up to date")
        return 0

    MANIFEST_PATH.parent.mkdir(parents=True, exist_ok=True)
    MANIFEST_PATH.write_text(json.dumps(manifest, indent=2, sort_keys=False) + "\n")
    print(f"\nWrote {MANIFEST_PATH} ({len(manifest['files'])} files)")
    if differences:
        print(
            f"note: {differences} file(s) differ from the reference set; "
            "this is expected only for a deliberate substitution."
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
