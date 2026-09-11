#!/usr/bin/env python3
import json
import os
import re
import sys
import tempfile

CONFIG_FILE = "__GAMMA_CONFIG_FILE__"
STATE_FILE = "__GAMMA_STATE_FILE__"

try:
    from PySide6.QtWidgets import (
        QApplication, QWidget, QVBoxLayout, QHBoxLayout, QScrollArea,
        QGroupBox, QFormLayout, QCheckBox, QLineEdit, QComboBox,
    )
    from PySide6.QtCore import Qt
except ImportError:
    sys.stderr.write(
        "gamma-configurator: PySide6 not found. Install it with: pip3 install PySide6\n"
    )
    sys.exit(1)

POINTER_COMMENT = "# Edit via Contents/MacOS/configurator — see it for descriptions and valid ranges."

# (section, family, KEY, kind, always_on, quoted, default). kind: bool | text | backend | retina.
# family: "d3dmetal" | "dxmt" | None (None = always shown/written, e.g. Core).
# always_on vars are always written when their family matches the selected
# backend — only their value changes, never their presence. The rest are
# "commentToggle": a checkbox controls whether the line is written to
# app.env at all; the value is remembered in configurator-state.json even
# while disabled, so re-enabling restores exactly what was typed before.
# quoted vars are wrapped in "..." in app.env; the GUI shows/edits them bare.
#
# Every D3DM_*/MTL_HUD_ENABLED name below is confirmed present as a literal
# getenv()-style string in the actual shipped binaries (no D3DMetal source
# exists to check against — it's Apple's closed GPTK 4.0b2):
#   strings lib64/apple_gptk/external/D3DMetal.framework/Versions/A/D3DMetal
#   strings lib64/apple_gptk/external/libd3dshared.dylib
# D3DM_LOGLEVEL_INFO was in the original template but is NOT a real env var —
# it only appears inside a diagnostic string ("...defaulting to
# D3DM_LOGLEVEL_INFO (%u)"), i.e. it's an internal enum constant name, not
# something getenv() reads. Dropped.
#
# Every DXMT_*/d3d11.*/dxgi.*/dxmt.* name below is confirmed against DXMT's
# own source (github.com/3Shain/dxmt, local checkout), specifically every
# `getOption<...>("key", ...)` call in src/ and every `getEnvVar("KEY")` call
# in src/util/config/config.cpp, src/util/log/log.cpp, src/d3d11/*,
# src/dxgi/*, src/dxmt/*. Cross-checking source (not just `strings` on the
# built .dll) caught a false positive: `d3d11.loH` appears in the binary as a
# raw string but it is only ever `Logger::s_instance("d3d11.log")` truncated
# in the strings scan — not a real config key. Dropped.
#
# Defaults are the exact values the original config/app.env.template shipped
# (now retired — this SCHEMA is the sole source of truth for defaults).
SCHEMA = [
    ("Core", None, "GAMMA_GRAPHICS_BACKEND", "backend", True, False, "dxmt"),
    ("Core", None, "MTL_HUD_ENABLED", "bool", True, False, "1"),
    ("Core", None, "WINEMSYNC", "bool", True, False, "1"),
    ("Core", None, "WINEESYNC", "bool", True, False, "1"),
    ("Core", None, "ROSETTA_ADVERTISE_AVX", "bool", True, False, "1"),
    ("Core", None, "WINEDEBUG", "text", True, True, "-all"),
    ("Core", None, "DEFAULT_GAME_ARGS", "text", True, True, "--dbg"),
    ("Core", None, "GAMMA_RETINA_MODE", "retina", True, False, "N"),
    ("Core", None, "GAMMA_RETINA_LOGPIXELS", "text", False, False, ""),
    ("D3DMetal (proven)", "d3dmetal", "D3DM_ENABLE_METALFX", "bool", True, False, "0"),
    ("D3DMetal (proven)", "d3dmetal", "D3DM_MAX_FPS", "text", True, False, "60"),
    ("D3DMetal (proven)", "d3dmetal", "D3DM_POSITION_INVARIANCE", "bool", True, False, "1"),
    ("D3DMetal (proven)", "d3dmetal", "D3DM_SAMPLE_NAN_TO_ZERO", "bool", True, False, "1"),
    ("D3DMetal (proven)", "d3dmetal", "D3DM_FLUSH_POS_INF_TO_NAN", "bool", True, False, "1"),
    ("D3DMetal (untested)", "d3dmetal", "D3DM_SHOW_HUD_STATS", "text", False, False, "1"),
    ("D3DMetal (untested)", "d3dmetal", "D3DM_LOD_BIAS", "text", False, False, "-0.5"),
    ("D3DMetal (untested)", "d3dmetal", "D3DM_MIN_LOD_CLAMP", "text", False, False, "0"),
    ("D3DMetal (untested)", "d3dmetal", "D3DM_SUPPORT_DXR", "text", False, False, "1"),
    ("D3DMetal (untested)", "d3dmetal", "D3DM_MTL4", "text", False, False, "1"),
    ("D3DMetal (untested)", "d3dmetal", "D3DM_IGNORE_D3D11_RENDER_BARRIERS", "text", False, False, "1"),
    ("D3DMetal (untested)", "d3dmetal", "D3DM_BOUNDS_CHECK", "text", False, False, "1"),
    ("D3DMetal (untested)", "d3dmetal", "D3DM_ERROR_MODE", "text", False, False, "1"),
    ("D3DMetal (untested)", "d3dmetal", "D3DM_NVNGX_PATH", "text", False, False, ""),
    ("D3DMetal (untested)", "d3dmetal", "D3DM_VENDOR_ID", "text", False, False, "0x10de"),
    ("D3DMetal (untested)", "d3dmetal", "D3DM_DEVICE_ID", "text", False, False, "0x2684"),
    ("D3DMetal (untested)", "d3dmetal", "D3DM_DEVICE_DESCRIPTION", "text", False, True, "NVIDIA GeForce RTX 4090"),
    ("D3DMetal (untested)", "d3dmetal", "D3DM_DEVICE_REVISION", "text", False, False, "0"),
    ("D3DMetal (untested)", "d3dmetal", "D3DM_DEVICE_SUBSYS", "text", False, False, "0"),
    ("DXMT", "dxmt", "DXMT_METALFX_SPATIAL_SWAPCHAIN", "bool", True, False, "0"),
    ("DXMT", "dxmt", "DXMT_ENABLE_NVEXT", "bool", True, False, "0"),
    ("DXMT", "dxmt", "DXMT_LOG_LEVEL", "text", False, False, "info"),
    ("DXMT", "dxmt", "DXMT_LOG_PATH", "text", False, False, ""),
    ("DXMT", "dxmt", "DXMT_SHADER_CACHE", "text", False, False, "1"),
    ("DXMT", "dxmt", "DXMT_SHADER_CACHE_PATH", "text", False, False, ""),
    ("DXMT", "dxmt", "DXMT_CAPTURE_FRAME", "text", False, False, ""),
    ("DXMT", "dxmt", "DXMT_CAPTURE_EXECUTABLE", "text", False, False, ""),
    ("DXMT", "dxmt", "DXMT_CONFIG_FILE", "text", False, False, ""),
    # DXMT_CONFIG itself is handled separately below (dxmt.conf-backed struct editor).
]
SCHEMA_BY_KEY = {row[2]: row for row in SCHEMA}

# DXMT_CONFIG sub-keys: (key, kind, choices, default). kind: bool | int | float | text | enum.
# Confirmed against dxmt/src/util/config/config.cpp's parseUserConfigLine
# (semicolon-split "key=value" pairs, same grammar as dxmt.conf) and every
# individual getOption<T>("key", default) call site listed above. Defaults
# are dxmt.conf's own recommended example values.
DXMT_CONFIG_KEYS = [
    ("d3d11.maxFeatureLevel", "enum",
     ["9_1", "9_2", "9_3", "10_0", "10_1", "11_0", "11_1", "12_0", "12_1"], "12_1"),
    ("d3d11.preferredMaxFrameRate", "int", None, "60"),
    ("d3d11.metalSpatialUpscaleFactor", "float", None, "2.0"),
    ("d3d11.ignoreMapFlagNoWait", "bool", None, "false"),
    ("d3d11.sampleNaNToZero", "bool", None, "false"),
    ("d3d11.defuseFma", "bool", None, "false"),
    ("dxmt.shaderMetalVersion", "enum", ["310", "320"], "310"),
    ("dxgi.customVendorId", "text", None, "0000"),
    ("dxgi.customDeviceId", "text", None, "0000"),
    ("dxgi.customDeviceDesc", "text", None, ""),
    ("dxgi.forceSDR", "bool", None, "false"),
    ("dxgi.handleAltTab", "bool", None, "false"),
]

# EXE_PATH/EXE_RUN_DIR are owned by interactive-setup.sh, never rendered as
# GUI fields; carried through every regeneration as opaque strings (quotes
# and all, exactly as found).
PASSTHROUGH_KEYS = ("EXE_PATH", "EXE_RUN_DIR")

# app.env has no trailing comments anymore (Configurator is the documented
# interface now) — just "export KEY=VALUE" or "#export KEY=VALUE".
LINE_RE = re.compile(r'^(?P<hash>#)?export\s+(?P<key>\w+)=(?P<value>.*)$')


def unquote(value):
    if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        return value[1:-1]
    return value


def atomic_write(path, text):
    directory = os.path.dirname(path) or "."
    fd, tmp_path = tempfile.mkstemp(dir=directory, prefix=".gamma-configurator-tmp-")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def parse_dxmt_config(raw):
    """'key=val;key2=val2' -> {key: val}. Ignores blanks/malformed fragments."""
    result = {}
    for part in raw.split(";"):
        part = part.strip()
        if not part or "=" not in part:
            continue
        k, v = part.split("=", 1)
        result[k.strip()] = unquote(v.strip())
    return result


def parse_env_lines(path):
    """Returns (vars: {KEY: (enabled, raw_value)}, passthrough: {KEY: raw_value},
    foreign: [raw_line, ...]) for whatever is currently on disk at path."""
    vars_found = {}
    passthrough = {}
    foreign = []
    if not os.path.exists(path):
        return vars_found, passthrough, foreign
    with open(path, "r") as f:
        raw_lines = f.readlines()
    for line in raw_lines:
        stripped = line.rstrip("\n")
        if not stripped or stripped == POINTER_COMMENT:
            continue
        m = LINE_RE.match(stripped)
        if not m:
            foreign.append(stripped)
            continue
        key = m.group("key")
        enabled = m.group("hash") is None
        raw_value = m.group("value")
        if key in PASSTHROUGH_KEYS:
            passthrough[key] = raw_value
        elif key in SCHEMA_BY_KEY or key == "DXMT_CONFIG":
            vars_found[key] = (enabled, raw_value)
        else:
            foreign.append(stripped)
    return vars_found, passthrough, foreign


def default_state():
    state = {"version": 1, "vars": {}, "dxmt_config": {}, "passthrough": {}, "foreign_lines": []}
    for _section, _family, key, _kind, always_on, _quoted, default in SCHEMA:
        state["vars"][key] = {"enabled": always_on, "value": default}
    for key, _kind, _choices, default in DXMT_CONFIG_KEYS:
        state["dxmt_config"][key] = {"enabled": False, "value": default}
    return state


def bootstrap_state_from_env():
    """First-ever launch: seed state from whatever interactive-setup.sh wrote."""
    state = default_state()
    vars_found, passthrough, foreign = parse_env_lines(CONFIG_FILE)
    for key, (enabled, raw_value) in vars_found.items():
        if key == "DXMT_CONFIG":
            for subkey, value in parse_dxmt_config(unquote(raw_value)).items():
                if subkey in state["dxmt_config"]:
                    state["dxmt_config"][subkey] = {"enabled": True, "value": value}
            continue
        quoted = SCHEMA_BY_KEY[key][5]
        value = unquote(raw_value) if quoted else raw_value
        state["vars"][key] = {"enabled": enabled, "value": value}
    state["passthrough"] = passthrough
    state["foreign_lines"] = foreign
    return state


def merge_foreign_lines(state):
    """Pick up anything hand-added to app.env since the last regeneration."""
    _, _, foreign = parse_env_lines(CONFIG_FILE)
    known = set(state["foreign_lines"])
    for line in foreign:
        if line not in known:
            state["foreign_lines"].append(line)
            known.add(line)


def load_or_bootstrap_state():
    if os.path.exists(STATE_FILE):
        with open(STATE_FILE, "r") as f:
            state = json.load(f)
    else:
        state = bootstrap_state_from_env()
        atomic_write(STATE_FILE, json.dumps(state, indent=2))
    merge_foreign_lines(state)
    return state


def generate_env(state):
    backend = state["vars"].get("GAMMA_GRAPHICS_BACKEND", {}).get("value", "d3dmetal")
    lines = [POINTER_COMMENT, ""]

    for key in PASSTHROUGH_KEYS:
        if key in state["passthrough"]:
            lines.append("export " + key + "=" + state["passthrough"][key])
    lines.append("")

    for _section, family, key, _kind, always_on, quoted, default in SCHEMA:
        if family is not None and family != backend:
            continue
        entry = state["vars"].get(key, {"enabled": always_on, "value": default})
        if not (always_on or entry["enabled"]):
            continue
        value = entry["value"]
        out_value = '"' + value + '"' if quoted else value
        lines.append("export " + key + "=" + out_value)

    if backend == "dxmt":
        active = {k: v["value"] for k, v in state["dxmt_config"].items() if v["enabled"]}
        if active:
            serialized = "".join(k + "=" + v + ";" for k, v in active.items())
            lines.append('export DXMT_CONFIG="' + serialized + '"')

    lines.extend(state["foreign_lines"])
    return "\n".join(lines) + "\n"


def save_state_and_env(state):
    merge_foreign_lines(state)
    atomic_write(STATE_FILE, json.dumps(state, indent=2))
    atomic_write(CONFIG_FILE, generate_env(state))


class ConfiguratorWindow(QWidget):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("GAMMA Configurator")
        self.resize(560, 640)
        self.state = load_or_bootstrap_state()
        self.family_boxes = []  # (family, QGroupBox)

        outer = QVBoxLayout(self)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        container = QWidget()
        vbox = QVBoxLayout(container)

        sections = {}
        for section, family, key, kind, always_on, quoted, default in SCHEMA:
            if section not in sections:
                box = QGroupBox(section)
                box.setLayout(QFormLayout())
                sections[section] = box
                vbox.addWidget(box)
                if family is not None:
                    self.family_boxes.append((family, box))
            row = self._build_row(key, kind, always_on, quoted, default)
            sections[section].layout().addRow(key, row)
            if key == "GAMMA_GRAPHICS_BACKEND":
                row.currentTextChanged.connect(self._update_family_visibility)

        dxmt_box = QGroupBox("DXMT_CONFIG (d3d11.* / dxgi.* / dxmt.*)")
        dxmt_box.setLayout(self._build_dxmt_config_form())
        vbox.addWidget(dxmt_box)
        self.family_boxes.append(("dxmt", dxmt_box))

        vbox.addStretch(1)
        scroll.setWidget(container)
        outer.addWidget(scroll)

        self._update_family_visibility(self.state["vars"]["GAMMA_GRAPHICS_BACKEND"]["value"])

    def _update_family_visibility(self, backend):
        for family, box in self.family_boxes:
            box.setVisible(family == backend)

    def _build_row(self, key, kind, always_on, quoted, default):
        entry = self.state["vars"].get(key, {"enabled": always_on, "value": default})
        value = entry["value"]
        active = True if always_on else entry["enabled"]

        if kind == "backend":
            combo = QComboBox()
            combo.addItems(["d3dmetal", "dxmt"])
            combo.setCurrentText(value if value in ("d3dmetal", "dxmt") else "d3dmetal")
            combo.currentTextChanged.connect(lambda text, k=key: self._save(k, True, text))
            return combo

        if kind == "retina":
            box = QCheckBox()
            box.setChecked(value.strip() == "Y")
            box.toggled.connect(lambda checked, k=key: self._save(k, True, "Y" if checked else "N"))
            return box

        if kind == "bool" and always_on:
            box = QCheckBox()
            box.setChecked(value.strip() == "1")
            box.toggled.connect(lambda checked, k=key: self._save(k, True, "1" if checked else "0"))
            return box

        row = QWidget()
        hbox = QHBoxLayout(row)
        hbox.setContentsMargins(0, 0, 0, 0)

        enable_box = None
        if not always_on:
            enable_box = QCheckBox()
            enable_box.setChecked(active)
            hbox.addWidget(enable_box)

        field = QLineEdit()
        field.setText(value)
        field.setEnabled(always_on or active)
        field.editingFinished.connect(
            lambda k=key, f=field, e=enable_box: self._save(
                k, e.isChecked() if e else True, f.text()
            )
        )

        if enable_box is not None:
            enable_box.toggled.connect(
                lambda checked, k=key, f=field: (
                    f.setEnabled(checked),
                    self._save(k, checked, f.text()),
                )
            )

        hbox.addWidget(field)
        return row

    def _save(self, key, enabled, value):
        self.state["vars"][key] = {"enabled": enabled, "value": value}
        save_state_and_env(self.state)

    # --- DXMT_CONFIG: structured sub-editor, folded into one file line ---

    def _build_dxmt_config_form(self):
        form = QFormLayout()
        for subkey, kind, choices, default in DXMT_CONFIG_KEYS:
            entry = self.state["dxmt_config"].get(subkey, {"enabled": False, "value": default})
            included = entry["enabled"]
            current = entry["value"]

            if kind == "bool":
                tri_box = QCheckBox()
                tri_box.setTristate(True)
                tri_box.setCheckState(
                    Qt.Checked if included and current.lower() == "true"
                    else Qt.Unchecked if included
                    else Qt.PartiallyChecked
                )

                def _on_tri_changed(state, k=subkey):
                    state = Qt.CheckState(state)
                    if state == Qt.PartiallyChecked:
                        self._save_dxmt(k, False, "false")
                    else:
                        self._save_dxmt(k, True, "true" if state == Qt.Checked else "false")

                tri_box.stateChanged.connect(_on_tri_changed)

                row = QWidget()
                hbox = QHBoxLayout(row)
                hbox.setContentsMargins(0, 0, 0, 0)
                hbox.addWidget(tri_box)
                form.addRow(subkey, row)
                continue

            enable_box = QCheckBox()
            enable_box.setChecked(included)

            if kind == "enum":
                field = QComboBox()
                field.addItems(choices)
                if current in choices:
                    field.setCurrentText(current)
                field.setEnabled(included)
                field.currentTextChanged.connect(
                    lambda text, k=subkey, e=enable_box: self._save_dxmt(k, e.isChecked(), text)
                )
                get_value = lambda f=field: f.currentText()
            else:
                field = QLineEdit()
                field.setText(current)
                field.setEnabled(included)
                field.editingFinished.connect(
                    lambda k=subkey, f=field, e=enable_box: self._save_dxmt(
                        k, e.isChecked(), f.text()
                    )
                )
                get_value = lambda f=field: f.text()

            enable_box.toggled.connect(
                lambda checked, k=subkey, f=field, gv=get_value: (
                    f.setEnabled(checked),
                    self._save_dxmt(k, checked, gv()),
                )
            )

            row = QWidget()
            hbox = QHBoxLayout(row)
            hbox.setContentsMargins(0, 0, 0, 0)
            hbox.addWidget(enable_box)
            hbox.addWidget(field)
            form.addRow(subkey, row)

        return form

    def _save_dxmt(self, subkey, enabled, value):
        self.state["dxmt_config"][subkey] = {"enabled": enabled, "value": value}
        save_state_and_env(self.state)


def main():
    app = QApplication(sys.argv)
    window = ConfiguratorWindow()
    window.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
