"""Run the real shell entry points against isolated, network-free build trees."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest


REPO = Path(__file__).resolve().parents[1]


def snapshot(root):
    """Include directory mtimes, file contents/modes and symlink targets."""
    result = {}
    for path in [root, *sorted(root.rglob("*"))]:
        stat = path.lstat()
        payload = None
        if path.is_symlink():
            payload = os.readlink(path)
        elif path.is_file():
            payload = hashlib.sha256(path.read_bytes()).hexdigest()
        result[str(path.relative_to(root))] = (stat.st_mode, stat.st_mtime_ns, payload)
    return result


@pytest.fixture
def build_tree(tmp_path):
    scripts = tmp_path / "scripts"
    scripts.mkdir()
    for name in (
        "build-wine.sh", "env.sh", "prepare-build-deps.sh", "apply-wine-series.sh"
    ):
        shutil.copy2(REPO / "scripts" / name, scripts / name)
    (tmp_path / "patches").mkdir()
    (tmp_path / "patches/series").write_text("example.patch\n")
    (tmp_path / "patches/example.patch").write_text("fixture patch\n")
    (tmp_path / "config").mkdir()
    (tmp_path / "config/engine-release.json").write_text(json.dumps({"patches": ["example.patch"]}))
    (tmp_path / "config/engine-version.txt").write_text("test-version\n")
    # Fail immediately if a preview tries to download, patch, compile or install.
    poison_bin = tmp_path / "poison-bin"
    poison_bin.mkdir()
    for command in ("curl", "arch", "tar", "patch", "make", "autoconf", "brew"):
        stub = poison_bin / command
        stub.write_text('#!/bin/sh\necho "Unexpected execution: $0" >&2\nexit 99\n')
        stub.chmod(0o755)
    env = dict(os.environ)
    for key in (
        "WINE_SRC", "WINE_INSTALL", "LLVM_MINGW", "HOMEBREW_PREFIX", "GIT_DIR",
        "OGOM_BUILD_DIR", "OGOM_ARCHIVES_DIR", "CROSSOVER_APP", "CROSSOVER_MOLTENVK",
        "GRAPHICS_INSTALL", "ANOMALY_BREW_PREFIX",
    ):
        env.pop(key, None)
    env.update(OGOM=str(tmp_path), HOME=str(tmp_path / "home"), PATH=f"{poison_bin}:{os.environ['PATH']}")
    return tmp_path, env


@pytest.mark.parametrize("state", ["absent", "source-only", "configured"])
@pytest.mark.parametrize("options", [
    [], ["--prepare-only"], ["--reconfigure"],
    ["--bootstrap-brew", "--install-deps"],
    ["--with-vulkan", "--vulkan-source", "crossover"],
])
def test_build_preview_is_read_only(build_tree, state, options):
    root, env = build_tree
    source = root / "build/wine-11.16/wine"
    if state != "absent":
        source.mkdir(parents=True)
        (source / "configure.ac").write_text("fixture\n")
        (source / "configure").write_text("fixture\n")
        (root / "home/.local/share/anomaly-wine/brew-x86").mkdir(parents=True)
    if state == "configured":
        build = source / "build64"
        build.mkdir()
        (build / "config.status").write_text("existing status\n")
        (build / ".anomaly-configure").write_text("old options\n")
        (build / "config.cache").write_text("existing cache\n")
    before = snapshot(root)
    result = subprocess.run(
        ["bash", str(root / "scripts/build-wine.sh"), "--dry-run", *options],
        cwd=root, env=env, text=True, capture_output=True, timeout=30,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert snapshot(root) == before
    if "--prepare-only" not in options:
        assert "+ patch -p1" in result.stdout
        assert "../configure" in result.stdout
        if state == "configured":
            assert "discarding config.cache" in result.stdout


def test_patch_preview_does_not_create_brew_directories(build_tree):
    root, env = build_tree
    (root / "home/.local/share/anomaly-wine/brew-x86").mkdir(parents=True)
    before = snapshot(root)
    result = subprocess.run(
        ["bash", str(root / "scripts/apply-wine-series.sh"), "--dry-run"],
        cwd=root, env=env, text=True, capture_output=True, timeout=30,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "+ patch -p1" in result.stdout
    assert snapshot(root) == before
