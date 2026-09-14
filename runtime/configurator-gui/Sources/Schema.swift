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

    SchemaEntry(section: "Core", family: nil, key: "WINEMSYNC", kind: .bool, alwaysOn: true, quoted: false, defaultValue: "1"),
    SchemaEntry(section: "Core", family: nil, key: "WINEESYNC", kind: .bool, alwaysOn: true, quoted: false, defaultValue: "1"),
    SchemaEntry(section: "Core", family: nil, key: "ROSETTA_ADVERTISE_AVX", kind: .bool, alwaysOn: true, quoted: false, defaultValue: "0"),
    SchemaEntry(section: "Core", family: nil, key: "GAMMA_RETINA_MODE", kind: .retina, alwaysOn: true, quoted: false, defaultValue: "N"),
    SchemaEntry(section: "Core", family: nil, key: "GAMMA_RETINA_LOGPIXELS", kind: .text, alwaysOn: false, quoted: false, defaultValue: ""),
    SchemaEntry(section: "Core", family: nil, key: "MTL_HUD_ENABLED", kind: .bool, alwaysOn: true, quoted: false, defaultValue: "0"),
    SchemaEntry(section: "Core", family: nil, key: "WINEDEBUG", kind: .text, alwaysOn: true, quoted: true, defaultValue: "-all"),

    SchemaEntry(section: "Core", family: nil, key: "DEFAULT_GAME_ARGS", kind: .text, alwaysOn: true, quoted: true, defaultValue: "--dbg"),

    SchemaEntry(section: "DXMT", family: "dxmt", key: "DXMT_METALFX_SPATIAL_SWAPCHAIN", kind: .bool, alwaysOn: true, quoted: false, defaultValue: "0"),
    SchemaEntry(section: "DXMT", family: "dxmt", key: "DXMT_ENABLE_NVEXT", kind: .bool, alwaysOn: true, quoted: false, defaultValue: "1"),

    SchemaEntry(section: "DXMT", family: "dxmt", key: "DXMT_SHADER_CACHE", kind: .text, alwaysOn: false, quoted: false, defaultValue: "1"),
    SchemaEntry(section: "DXMT", family: "dxmt", key: "DXMT_SHADER_CACHE_PATH", kind: .text, alwaysOn: false, quoted: false, defaultValue: ""),

    SchemaEntry(section: "DXMT", family: "dxmt", key: "DXMT_LOG_LEVEL", kind: .text, alwaysOn: false, quoted: false, defaultValue: "none"),
    SchemaEntry(section: "DXMT", family: "dxmt", key: "DXMT_LOG_PATH", kind: .text, alwaysOn: false, quoted: false, defaultValue: ""),
    SchemaEntry(section: "DXMT", family: "dxmt", key: "DXMT_CAPTURE_FRAME", kind: .text, alwaysOn: false, quoted: false, defaultValue: ""),
    SchemaEntry(section: "DXMT", family: "dxmt", key: "DXMT_CAPTURE_EXECUTABLE", kind: .text, alwaysOn: false, quoted: false, defaultValue: ""),
    SchemaEntry(section: "DXMT", family: "dxmt", key: "DXMT_CONFIG_FILE", kind: .text, alwaysOn: false, quoted: false, defaultValue: ""),

    SchemaEntry(section: "D3DMetal", family: "d3dmetal", key: "D3DM_ENABLE_METALFX", kind: .bool, alwaysOn: true, quoted: false, defaultValue: "0"),
    SchemaEntry(section: "D3DMetal", family: "d3dmetal", key: "D3DM_MAX_FPS", kind: .text, alwaysOn: true, quoted: false, defaultValue: "60"),
    SchemaEntry(section: "D3DMetal", family: "d3dmetal", key: "D3DM_POSITION_INVARIANCE", kind: .bool, alwaysOn: true, quoted: false, defaultValue: "1"),
    SchemaEntry(section: "D3DMetal", family: "d3dmetal", key: "D3DM_SAMPLE_NAN_TO_ZERO", kind: .bool, alwaysOn: true, quoted: false, defaultValue: "1"),
    SchemaEntry(section: "D3DMetal", family: "d3dmetal", key: "D3DM_FLUSH_POS_INF_TO_NAN", kind: .bool, alwaysOn: true, quoted: false, defaultValue: "1"),

    SchemaEntry(section: "D3DMetal", family: "d3dmetal", key: "D3DM_SHOW_HUD_STATS", kind: .text, alwaysOn: false, quoted: false, defaultValue: "1"),
    SchemaEntry(section: "D3DMetal", family: "d3dmetal", key: "D3DM_LOD_BIAS", kind: .text, alwaysOn: false, quoted: false, defaultValue: "-0.5"),
    SchemaEntry(section: "D3DMetal", family: "d3dmetal", key: "D3DM_MIN_LOD_CLAMP", kind: .text, alwaysOn: false, quoted: false, defaultValue: "0"),
    SchemaEntry(section: "D3DMetal", family: "d3dmetal", key: "D3DM_SUPPORT_DXR", kind: .text, alwaysOn: false, quoted: false, defaultValue: "1"),
    SchemaEntry(section: "D3DMetal", family: "d3dmetal", key: "D3DM_MTL4", kind: .text, alwaysOn: false, quoted: false, defaultValue: "1"),
    SchemaEntry(section: "D3DMetal", family: "d3dmetal", key: "D3DM_IGNORE_D3D11_RENDER_BARRIERS", kind: .text, alwaysOn: false, quoted: false, defaultValue: "1"),
    SchemaEntry(section: "D3DMetal", family: "d3dmetal", key: "D3DM_BOUNDS_CHECK", kind: .text, alwaysOn: false, quoted: false, defaultValue: "1"),
    SchemaEntry(section: "D3DMetal", family: "d3dmetal", key: "D3DM_ERROR_MODE", kind: .text, alwaysOn: false, quoted: false, defaultValue: "1"),
    SchemaEntry(section: "D3DMetal", family: "d3dmetal", key: "D3DM_NVNGX_PATH", kind: .text, alwaysOn: false, quoted: false, defaultValue: ""),
    SchemaEntry(section: "D3DMetal", family: "d3dmetal", key: "D3DM_VENDOR_ID", kind: .text, alwaysOn: false, quoted: false, defaultValue: "0x10de"),
    SchemaEntry(section: "D3DMetal", family: "d3dmetal", key: "D3DM_DEVICE_ID", kind: .text, alwaysOn: false, quoted: false, defaultValue: "0x2684"),
    SchemaEntry(section: "D3DMetal", family: "d3dmetal", key: "D3DM_DEVICE_DESCRIPTION", kind: .text, alwaysOn: false, quoted: true, defaultValue: "NVIDIA GeForce RTX 4090"),
    SchemaEntry(section: "D3DMetal", family: "d3dmetal", key: "D3DM_DEVICE_REVISION", kind: .text, alwaysOn: false, quoted: false, defaultValue: "0"),
    SchemaEntry(section: "D3DMetal", family: "d3dmetal", key: "D3DM_DEVICE_SUBSYS", kind: .text, alwaysOn: false, quoted: false, defaultValue: "0"),


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
    DXMTConfigEntry(key: "d3d11.metalSpatialUpscaleFactor", kind: .float, choices: nil, defaultValue: "1.0"),
    DXMTConfigEntry(key: "d3d11.ignoreMapFlagNoWait", kind: .bool, choices: nil, defaultValue: "false"),
    DXMTConfigEntry(key: "d3d11.sampleNaNToZero", kind: .bool, choices: nil, defaultValue: "false"),
    DXMTConfigEntry(key: "d3d11.defuseFma", kind: .bool, choices: nil, defaultValue: "false"),
    DXMTConfigEntry(key: "dxmt.shaderMetalVersion", kind: .enumChoice, choices: ["310", "320"], defaultValue: "310"),
    DXMTConfigEntry(key: "dxgi.customVendorId", kind: .text, choices: nil, defaultValue: ""),
    DXMTConfigEntry(key: "dxgi.customDeviceId", kind: .text, choices: nil, defaultValue: ""),
    DXMTConfigEntry(key: "dxgi.customDeviceDesc", kind: .text, choices: nil, defaultValue: ""),
    DXMTConfigEntry(key: "dxgi.forceSDR", kind: .bool, choices: nil, defaultValue: "false"),
    DXMTConfigEntry(key: "dxgi.handleAltTab", kind: .bool, choices: nil, defaultValue: "false"),
]

// EXE_PATH/EXE_RUN_DIR are owned by interactive-setup.sh, never rendered as
// GUI fields; carried through every regeneration as opaque strings.
let passthroughKeys = ["EXE_PATH", "EXE_RUN_DIR"]

let pointerComment = "# Edit via Contents/Resources/Configurator.app — see it for descriptions and valid ranges."

// User-facing labels shown by default; the raw env-var/DXMT_CONFIG key is
// shown on hover (.help) instead, so this file stays the single place that
// needs updating when a key's wording changes.
let friendlyLabels: [String: String] = [
    "GAMMA_GRAPHICS_BACKEND": "Graphics Backend",
    "MTL_HUD_ENABLED": "Metal Performance HUD",
    "WINEMSYNC": "Msync",
    "WINEESYNC": "Esync",
    "ROSETTA_ADVERTISE_AVX": "Advertise AVX Under Rosetta",
    "WINEDEBUG": "Wine Debug Channels",
    "DEFAULT_GAME_ARGS": "Launch Arguments",
    "GAMMA_RETINA_MODE": "Retina Display Mode",
    "GAMMA_RETINA_LOGPIXELS": "Retina DPI Override",

    "D3DM_ENABLE_METALFX": "Enable MetalFX Upscaling",
    "D3DM_MAX_FPS": "Max Frame Rate",
    "D3DM_POSITION_INVARIANCE": "Position Invariance",
    "D3DM_SAMPLE_NAN_TO_ZERO": "Clamp NaN Samples To Zero",
    "D3DM_FLUSH_POS_INF_TO_NAN": "Flush +Inf To NaN",

    "D3DM_SHOW_HUD_STATS": "Show HUD Stats",
    "D3DM_LOD_BIAS": "Texture LOD Bias",
    "D3DM_MIN_LOD_CLAMP": "Minimum LOD Clamp",
    "D3DM_SUPPORT_DXR": "DXR Raytracing Support",
    "D3DM_MTL4": "Use Metal 4",
    "D3DM_IGNORE_D3D11_RENDER_BARRIERS": "Ignore D3D11 Render Barriers",
    "D3DM_BOUNDS_CHECK": "Bounds Checking",
    "D3DM_ERROR_MODE": "Error Mode",
    "D3DM_NVNGX_PATH": "NVIDIA NGX Path Override",
    "D3DM_VENDOR_ID": "Reported Vendor ID",
    "D3DM_DEVICE_ID": "Reported Device ID",
    "D3DM_DEVICE_DESCRIPTION": "Reported Device Name",
    "D3DM_DEVICE_REVISION": "Reported Device Revision",
    "D3DM_DEVICE_SUBSYS": "Reported Subsystem ID",

    "DXMT_METALFX_SPATIAL_SWAPCHAIN": "MetalFX Spatial Upscaling",
    "DXMT_ENABLE_NVEXT": "Enable NVIDIA Extensions (NVAPI)",
    "DXMT_LOG_LEVEL": "Log Level",
    "DXMT_LOG_PATH": "Log File Path",
    "DXMT_SHADER_CACHE": "Shader Cache",
    "DXMT_SHADER_CACHE_PATH": "Shader Cache Path",
    "DXMT_CAPTURE_FRAME": "Frame Capture Trigger",
    "DXMT_CAPTURE_EXECUTABLE": "Metal Frame Capture Tool",
    "DXMT_CONFIG_FILE": "DXMT Config File Override",

    "d3d11.maxFeatureLevel": "Max DirectX Feature Level",
    "d3d11.preferredMaxFrameRate": "Preferred Max Frame Rate",
    "d3d11.metalSpatialUpscaleFactor": "Spatial Upscale Factor",
    "d3d11.ignoreMapFlagNoWait": "Ignore Map No-Wait Flag",
    "d3d11.sampleNaNToZero": "Clamp NaN Samples To Zero",
    "d3d11.defuseFma": "Disable Fused Multiply-Add",
    "dxmt.shaderMetalVersion": "Shader Metal Language Version",
    "dxgi.customVendorId": "Custom Vendor ID",
    "dxgi.customDeviceId": "Custom Device ID",
    "dxgi.customDeviceDesc": "Custom Device Description",
    "dxgi.forceSDR": "Force SDR Output",
    "dxgi.handleAltTab": "Handle Alt+Tab",
]

func friendlyLabel(for key: String) -> String {
    friendlyLabels[key] ?? key
}
