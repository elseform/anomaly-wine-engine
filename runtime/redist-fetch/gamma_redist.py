"""Obtain the Microsoft redistributable DLLs the GAMMA Wine engine needs.

The engine used to ship these DLLs inside its own archive. It no longer does:
they are Microsoft's to distribute, not ours. Instead the engine declares what
it needs in `share/gamma/redist-manifest.json` and this module fetches exactly
that set from Microsoft's own public installers at wrapper-setup time.

Two properties make this safe to do unattended:

* Every installer is pinned by URL *and* SHA-256, so extraction is
  reproducible and yields byte-identical DLLs.
* Every extracted DLL is checked against its own recorded SHA-256 before it is
  installed. A mismatch anywhere aborts instead of installing something we did
  not validate.

Nothing here needs a third-party tool. macOS ships bsdtar/libarchive, which
reads Microsoft Cabinet archives, and the one container libarchive cannot open
by itself — the WiX burn bundle that wraps `vc_redist.x64.exe` — is unwrapped
by locating its appended cabinet directly.
"""

from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import tempfile
import urllib.request
from pathlib import Path
from typing import Callable, Iterable, Sequence

BSDTAR = "/usr/bin/bsdtar"
CAB_MAGIC = b"MSCF"
_CHUNK = 1 << 20


class RedistError(Exception):
    """A redistributable could not be obtained, verified, or installed."""


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(_CHUNK):
            digest.update(chunk)
    return digest.hexdigest()


def load_manifest(path: Path) -> dict:
    try:
        manifest = json.loads(Path(path).read_text())
    except (OSError, ValueError) as error:
        raise RedistError(f"unreadable redist manifest {path}: {error}") from error
    version = manifest.get("schemaVersion")
    if not isinstance(version, int) or version < 1:
        raise RedistError(f"unsupported redist manifest schemaVersion: {version!r}")
    if not manifest.get("installers") or not manifest.get("files"):
        raise RedistError(f"redist manifest {path} declares no installers or files")
    return manifest


# --- containers -------------------------------------------------------------


def _find_appended_cabinet(data: bytes) -> tuple[int, int]:
    """Locate the cabinet a WiX burn bundle appends to its PE image.

    Returns the (offset, size) of the largest well-formed cabinet found, which
    is the payload container; the smaller one holds the bundle's own UX
    resources.
    """
    best: tuple[int, int] | None = None
    start = 0
    while (found := data.find(CAB_MAGIC, start)) >= 0:
        start = found + len(CAB_MAGIC)
        if found + 12 > len(data):
            continue
        size = int.from_bytes(data[found + 8:found + 12], "little")
        if size <= 0 or found + size > len(data):
            continue
        if best is None or size > best[1]:
            best = (found, size)
    if best is None:
        raise RedistError("no appended cabinet found in the installer")
    return best


def _unwrap_burn(installer: Path, work_dir: Path) -> Path:
    offset, size = _find_appended_cabinet(installer.read_bytes())
    container = work_dir / "burn-payload.cab"
    with installer.open("rb") as src, container.open("wb") as dst:
        src.seek(offset)
        remaining = size
        while remaining > 0:
            chunk = src.read(min(_CHUNK, remaining))
            if not chunk:
                break
            dst.write(chunk)
            remaining -= len(chunk)
    return container


def _container_for(installer: Path, container_kind: str, work_dir: Path) -> Path:
    if container_kind == "cab":
        return installer
    if container_kind == "wix-burn":
        return _unwrap_burn(installer, work_dir)
    raise RedistError(f"unknown installer container kind: {container_kind!r}")


def _extract_member(archive: Path, member: str, into: Path) -> Path:
    """Extract one member out of a cabinet, returning the extracted path."""
    into.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(
        [BSDTAR, "-xf", str(archive), "-C", str(into), member],
        capture_output=True,
        text=True,
    )
    extracted = into / member
    if result.returncode != 0 or not extracted.is_file():
        detail = (result.stderr or result.stdout or "").strip().splitlines()
        raise RedistError(
            f"could not extract {member} from {archive.name}"
            + (f": {detail[0]}" if detail else "")
        )
    return extracted


def _extract_path(container: Path, member_path: Sequence[str], work_dir: Path) -> Path:
    """Walk a nested member path, e.g. ["a12", "vcruntime140.dll_amd64"]."""
    current = container
    for depth, member in enumerate(member_path):
        stage = work_dir / f"stage{depth}"
        current = _extract_member(current, member, stage)
    return current


# --- installers -------------------------------------------------------------


def _verify(path: Path, expected_sha256: str, what: str) -> None:
    actual = _sha256(path)
    if actual.lower() != expected_sha256.lower():
        raise RedistError(
            f"{what} failed its checksum check\n"
            f"  expected {expected_sha256}\n"
            f"  actual   {actual}"
        )


def resolve_installer(
    name: str,
    spec: dict,
    cache_dir: Path,
    search_dirs: Iterable[Path] = (),
    log: Callable[[str], None] = lambda _message: None,
) -> Path:
    """Find, or download, one pinned installer and verify it.

    A copy the user supplied themselves wins over the cache, and the cache wins
    over the network, so a machine that already has the installers never has to
    reach Microsoft at all.
    """
    filename = spec["filename"]
    expected = spec["sha256"]

    for directory in search_dirs:
        candidate = Path(directory).expanduser() / filename
        if not candidate.is_file():
            continue
        try:
            _verify(candidate, expected, f"{filename} in {directory}")
        except RedistError as error:
            # Someone else's build of the same installer is not usable, but it
            # is also not a reason to fail: fall through to the pinned copy.
            log(f"ignoring {candidate}: {error.args[0].splitlines()[0]}")
            continue
        log(f"Using supplied installer: {candidate}")
        return candidate

    cache_dir.mkdir(parents=True, exist_ok=True)
    cached = cache_dir / filename
    if cached.is_file():
        try:
            _verify(cached, expected, f"cached {filename}")
            log(f"Using cached installer: {cached}")
            return cached
        except RedistError as error:
            log(f"Discarding {cached}: {error.args[0].splitlines()[0]}")
            cached.unlink(missing_ok=True)

    url = spec["url"]
    log(f"Downloading {filename} ({spec.get('sizeLabel', 'unknown size')}) from {url}")
    incoming = cache_dir / f".{filename}.incoming"
    try:
        with urllib.request.urlopen(url) as response, incoming.open("wb") as dst:
            shutil.copyfileobj(response, dst, _CHUNK)
    except OSError as error:
        incoming.unlink(missing_ok=True)
        raise RedistError(f"could not download {filename} from {url}: {error}") from error

    try:
        _verify(incoming, expected, f"downloaded {filename}")
    except RedistError:
        incoming.unlink(missing_ok=True)
        raise
    incoming.replace(cached)
    return cached


def install(
    manifest: dict,
    system32: Path,
    cache_dir: Path,
    search_dirs: Iterable[Path] = (),
    log: Callable[[str], None] = lambda _message: None,
) -> list[str]:
    """Install every DLL the manifest declares, returning their stems.

    The stems are what the caller registers as `native,builtin` DLL overrides.
    """
    search_dirs = [Path(d).expanduser() for d in search_dirs]
    files = manifest["files"]
    installers = manifest["installers"]

    # Only fetch an installer if something still needs it.
    wanted: dict[str, list[dict]] = {}
    for entry in files:
        target = system32 / entry["target"]
        if target.is_file() and _sha256(target) == entry["sha256"].lower():
            log(f"{entry['target']} already present and verified")
            continue
        wanted.setdefault(entry["installer"], []).append(entry)

    if not wanted:
        log("All redistributables already present")
        return sorted(Path(entry["target"]).stem for entry in files)

    system32.mkdir(parents=True, exist_ok=True)
    for installer_name, entries in sorted(wanted.items()):
        spec = installers.get(installer_name)
        if spec is None:
            raise RedistError(f"manifest references unknown installer {installer_name!r}")
        installer = resolve_installer(installer_name, spec, cache_dir, search_dirs, log)

        with tempfile.TemporaryDirectory(prefix="gamma-redist-") as tmp:
            work = Path(tmp)
            kind = spec.get("container", "cab")
            if kind == "raw":
                # The download is the DLL itself; nothing to unpack.
                for entry in entries:
                    _verify(installer, entry["sha256"], entry["target"])
                    shutil.copy2(installer, system32 / entry["target"])
                    log(f"Installed {entry['target']}")
                continue

            container = _container_for(installer, kind, work)
            for index, entry in enumerate(entries):
                member_path = entry.get("memberPath") or []
                if not member_path:
                    raise RedistError(
                        f"manifest entry for {entry['target']} has no memberPath"
                    )
                extracted = _extract_path(container, member_path, work / f"e{index}")
                _verify(extracted, entry["sha256"], entry["target"])
                shutil.copy2(extracted, system32 / entry["target"])
                log(f"Installed {entry['target']}")

    return sorted(Path(entry["target"]).stem for entry in files)
