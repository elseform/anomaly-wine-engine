import Foundation

// Direct port of runtime/configurator/configurator.py's SCHEMA. Keep this
// list byte-for-byte equivalent to the Python source (same keys, sections,
// kinds, always_on/quoted flags, defaults) — it defines what app.env lines
// get written, and existing installs' app.env/configurator-state.json must
// stay compatible across the Python -> Swift rewrite.
enum SchemaKind {
    case bool
    case text
    case backend
    case retina
}

struct SchemaEntry {
    let section: String
    let family: String?  // nil = always shown/written (Core); "d3dmetal" | "dxmt" otherwise
    let key: String
    let kind: SchemaKind
    let alwaysOn: Bool
    let quoted: Bool
    let defaultValue: String
}

let schema: [SchemaEntry] = [
    SchemaEntry(section: "Core", family: nil, key: "GAMMA_GRAPHICS_BACKEND", kind: .backend, alwaysOn: true, quoted: false, defaultValue: "dxmt"),
    SchemaEntry(section: "Core", family: nil, key: "MTL_HUD_ENABLED", kind: .bool, alwaysOn: true, quoted: false, defaultValue: "0"),
    SchemaEntry(section: "Core", family: nil, key: "WINEMSYNC", kind: .bool, alwaysOn: true, quoted: false, defaultValue: "1"),
    SchemaEntry(section: "Core", family: nil, key: "WINEESYNC", kind: .bool, alwaysOn: true, quoted: false, defaultValue: "1"),
    SchemaEntry(section: "Core", family: nil, key: "ROSETTA_ADVERTISE_AVX", kind: .bool, alwaysOn: true, quoted: false, defaultValue: "0"),
    SchemaEntry(section: "Core", family: nil, key: "WINEDEBUG", kind: .text, alwaysOn: true, quoted: true, defaultValue: "-all"),
    SchemaEntry(section: "Core", family: nil, key: "DEFAULT_GAME_ARGS", kind: .text, alwaysOn: true, quoted: true, defaultValue: ""),
    SchemaEntry(section: "Core", family: nil, key: "GAMMA_RETINA_MODE", kind: .retina, alwaysOn: true, quoted: false, defaultValue: "N"),
    SchemaEntry(section: "Core", family: nil, key: "GAMMA_RETINA_LOGPIXELS", kind: .text, alwaysOn: false, quoted: false, defaultValue: ""),

    SchemaEntry(section: "D3DMetal (proven)", family: "d3dmetal", key: "D3DM_ENABLE_METALFX", kind: .bool, alwaysOn: true, quoted: false, defaultValue: "0"),
    SchemaEntry(section: "D3DMetal (proven)", family: "d3dmetal", key: "D3DM_MAX_FPS", kind: .text, alwaysOn: true, quoted: false, defaultValue: "60"),
    SchemaEntry(section: "D3DMetal (proven)", family: "d3dmetal", key: "D3DM_POSITION_INVARIANCE", kind: .bool, alwaysOn: true, quoted: false, defaultValue: "1"),
    SchemaEntry(section: "D3DMetal (proven)", family: "d3dmetal", key: "D3DM_SAMPLE_NAN_TO_ZERO", kind: .bool, alwaysOn: true, quoted: false, defaultValue: "1"),
    SchemaEntry(section: "D3DMetal (proven)", family: "d3dmetal", key: "D3DM_FLUSH_POS_INF_TO_NAN", kind: .bool, alwaysOn: true, quoted: false, defaultValue: "1"),

    SchemaEntry(section: "D3DMetal (untested)", family: "d3dmetal", key: "D3DM_SHOW_HUD_STATS", kind: .text, alwaysOn: false, quoted: false, defaultValue: "1"),
    SchemaEntry(section: "D3DMetal (untested)", family: "d3dmetal", key: "D3DM_LOD_BIAS", kind: .text, alwaysOn: false, quoted: false, defaultValue: "-0.5"),
    SchemaEntry(section: "D3DMetal (untested)", family: "d3dmetal", key: "D3DM_MIN_LOD_CLAMP", kind: .text, alwaysOn: false, quoted: false, defaultValue: "0"),
    SchemaEntry(section: "D3DMetal (untested)", family: "d3dmetal", key: "D3DM_SUPPORT_DXR", kind: .text, alwaysOn: false, quoted: false, defaultValue: "1"),
    SchemaEntry(section: "D3DMetal (untested)", family: "d3dmetal", key: "D3DM_MTL4", kind: .text, alwaysOn: false, quoted: false, defaultValue: "1"),
    SchemaEntry(section: "D3DMetal (untested)", family: "d3dmetal", key: "D3DM_IGNORE_D3D11_RENDER_BARRIERS", kind: .text, alwaysOn: false, quoted: false, defaultValue: "1"),
    SchemaEntry(section: "D3DMetal (untested)", family: "d3dmetal", key: "D3DM_BOUNDS_CHECK", kind: .text, alwaysOn: false, quoted: false, defaultValue: "1"),
    SchemaEntry(section: "D3DMetal (untested)", family: "d3dmetal", key: "D3DM_ERROR_MODE", kind: .text, alwaysOn: false, quoted: false, defaultValue: "1"),
    SchemaEntry(section: "D3DMetal (untested)", family: "d3dmetal", key: "D3DM_NVNGX_PATH", kind: .text, alwaysOn: false, quoted: false, defaultValue: ""),
    SchemaEntry(section: "D3DMetal (untested)", family: "d3dmetal", key: "D3DM_VENDOR_ID", kind: .text, alwaysOn: false, quoted: false, defaultValue: "0x10de"),
    SchemaEntry(section: "D3DMetal (untested)", family: "d3dmetal", key: "D3DM_DEVICE_ID", kind: .text, alwaysOn: false, quoted: false, defaultValue: "0x2684"),
    SchemaEntry(section: "D3DMetal (untested)", family: "d3dmetal", key: "D3DM_DEVICE_DESCRIPTION", kind: .text, alwaysOn: false, quoted: true, defaultValue: "NVIDIA GeForce RTX 4090"),
    SchemaEntry(section: "D3DMetal (untested)", family: "d3dmetal", key: "D3DM_DEVICE_REVISION", kind: .text, alwaysOn: false, quoted: false, defaultValue: "0"),
    SchemaEntry(section: "D3DMetal (untested)", family: "d3dmetal", key: "D3DM_DEVICE_SUBSYS", kind: .text, alwaysOn: false, quoted: false, defaultValue: "0"),

    SchemaEntry(section: "DXMT", family: "dxmt", key: "DXMT_METALFX_SPATIAL_SWAPCHAIN", kind: .bool, alwaysOn: true, quoted: false, defaultValue: "0"),
    SchemaEntry(section: "DXMT", family: "dxmt", key: "DXMT_ENABLE_NVEXT", kind: .bool, alwaysOn: true, quoted: false, defaultValue: "0"),
    SchemaEntry(section: "DXMT", family: "dxmt", key: "DXMT_LOG_LEVEL", kind: .text, alwaysOn: false, quoted: false, defaultValue: "info"),
    SchemaEntry(section: "DXMT", family: "dxmt", key: "DXMT_LOG_PATH", kind: .text, alwaysOn: false, quoted: false, defaultValue: ""),
    SchemaEntry(section: "DXMT", family: "dxmt", key: "DXMT_SHADER_CACHE", kind: .text, alwaysOn: false, quoted: false, defaultValue: "1"),
    SchemaEntry(section: "DXMT", family: "dxmt", key: "DXMT_SHADER_CACHE_PATH", kind: .text, alwaysOn: false, quoted: false, defaultValue: ""),
    SchemaEntry(section: "DXMT", family: "dxmt", key: "DXMT_CAPTURE_FRAME", kind: .text, alwaysOn: false, quoted: false, defaultValue: ""),
    SchemaEntry(section: "DXMT", family: "dxmt", key: "DXMT_CAPTURE_EXECUTABLE", kind: .text, alwaysOn: false, quoted: false, defaultValue: ""),
    SchemaEntry(section: "DXMT", family: "dxmt", key: "DXMT_CONFIG_FILE", kind: .text, alwaysOn: false, quoted: false, defaultValue: ""),
    // DXMT_CONFIG itself is handled separately (dxmtConfig / dxmtConfigKeys below).
]

let schemaByKey: [String: SchemaEntry] = Dictionary(uniqueKeysWithValues: schema.map { ($0.key, $0) })

// Preserves section order for display (Dictionary/Set would not).
let schemaSections: [String] = {
    var seen = Set<String>()
    var order: [String] = []
    for entry in schema where !seen.contains(entry.section) {
        seen.insert(entry.section)
        order.append(entry.section)
    }
    return order
}()

enum DXMTConfigKind {
    case bool
    case int
    case float
    case text
    case enumChoice
}

struct DXMTConfigEntry {
    let key: String
    let kind: DXMTConfigKind
    let choices: [String]?
    let defaultValue: String
}

// Direct port of DXMT_CONFIG_KEYS.
let dxmtConfigKeys: [DXMTConfigEntry] = [
    DXMTConfigEntry(key: "d3d11.maxFeatureLevel", kind: .enumChoice, choices: ["9_1", "9_2", "9_3", "10_0", "10_1", "11_0", "11_1", "12_0", "12_1"], defaultValue: "11_1"),
    DXMTConfigEntry(key: "d3d11.preferredMaxFrameRate", kind: .int, choices: nil, defaultValue: "60"),
    DXMTConfigEntry(key: "d3d11.metalSpatialUpscaleFactor", kind: .float, choices: nil, defaultValue: "2.0"),
    DXMTConfigEntry(key: "d3d11.ignoreMapFlagNoWait", kind: .bool, choices: nil, defaultValue: "false"),
    DXMTConfigEntry(key: "d3d11.sampleNaNToZero", kind: .bool, choices: nil, defaultValue: "false"),
    DXMTConfigEntry(key: "d3d11.defuseFma", kind: .bool, choices: nil, defaultValue: "false"),
    DXMTConfigEntry(key: "dxmt.shaderMetalVersion", kind: .enumChoice, choices: ["310", "320"], defaultValue: "310"),
    DXMTConfigEntry(key: "dxgi.customVendorId", kind: .text, choices: nil, defaultValue: "10DE"),
    DXMTConfigEntry(key: "dxgi.customDeviceId", kind: .text, choices: nil, defaultValue: "2684"),
    DXMTConfigEntry(key: "dxgi.customDeviceDesc", kind: .text, choices: nil, defaultValue: "GeForce RTX 4090"),
    DXMTConfigEntry(key: "dxgi.forceSDR", kind: .bool, choices: nil, defaultValue: "false"),
    DXMTConfigEntry(key: "dxgi.handleAltTab", kind: .bool, choices: nil, defaultValue: "false"),
]

// EXE_PATH/EXE_RUN_DIR are owned by interactive-setup.sh, never rendered as
// GUI fields; carried through every regeneration as opaque strings.
let passthroughKeys = ["EXE_PATH", "EXE_RUN_DIR"]

let pointerComment = "# Edit via Contents/Resources/Configurator.app — see it for descriptions and valid ranges."
