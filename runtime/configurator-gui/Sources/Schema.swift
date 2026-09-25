import Foundation

// Started as a port of the former runtime/configurator/configurator.py's
// SCHEMA; this is the only copy now. It defines what app.env lines get
// written, so keys, kinds and always_on/quoted flags must stay compatible with
// existing installs' app.env files. Where each setting appears in the window
// is decided separately, by mainGroups/advancedGroups below.
// Defaults must match the app.env seed in gamma-setup-tool's
// interactive_setup.py, which is what a new wrapper actually starts from.
enum SchemaKind {
    case bool
    case text
    case retina
}

struct SchemaEntry {
    let key: String
    let kind: SchemaKind
    let alwaysOn: Bool
    let quoted: Bool
    let defaultValue: String
}

let schema: [SchemaEntry] = [
    // Not shown: D3DMetal is no longer offered, so this is always dxmt. Still
    // written because the launcher and cxcompatdb read it.
    SchemaEntry(key: "GAMMA_GRAPHICS_BACKEND", kind: .text, alwaysOn: true, quoted: false, defaultValue: "dxmt"),

    SchemaEntry(key: "WINEMSYNC", kind: .bool, alwaysOn: true, quoted: false, defaultValue: "1"),
    SchemaEntry(key: "WINEESYNC", kind: .bool, alwaysOn: true, quoted: false, defaultValue: "1"),
    SchemaEntry(key: "ROSETTA_ADVERTISE_AVX", kind: .bool, alwaysOn: true, quoted: false, defaultValue: "0"),
    SchemaEntry(key: "GAMMA_RETINA_MODE", kind: .retina, alwaysOn: true, quoted: false, defaultValue: "N"),
    SchemaEntry(key: "GAMMA_RETINA_LOGPIXELS", kind: .text, alwaysOn: false, quoted: false, defaultValue: ""),
    SchemaEntry(key: "MTL_HUD_ENABLED", kind: .bool, alwaysOn: true, quoted: false, defaultValue: "0"),
    SchemaEntry(key: "WINEDEBUG", kind: .text, alwaysOn: true, quoted: true, defaultValue: "-all"),

    SchemaEntry(key: "DEFAULT_GAME_ARGS", kind: .text, alwaysOn: true, quoted: true, defaultValue: ""),

    SchemaEntry(key: "DXMT_METALFX_SPATIAL_SWAPCHAIN", kind: .bool, alwaysOn: true, quoted: false, defaultValue: "0"),
    SchemaEntry(key: "DXMT_ENABLE_NVEXT", kind: .bool, alwaysOn: true, quoted: false, defaultValue: "1"),

    SchemaEntry(key: "DXMT_SHADER_CACHE", kind: .text, alwaysOn: false, quoted: false, defaultValue: "1"),
    SchemaEntry(key: "DXMT_SHADER_CACHE_PATH", kind: .text, alwaysOn: false, quoted: false, defaultValue: ""),

    SchemaEntry(key: "DXMT_LOG_LEVEL", kind: .text, alwaysOn: false, quoted: false, defaultValue: "none"),
    SchemaEntry(key: "DXMT_LOG_PATH", kind: .text, alwaysOn: false, quoted: false, defaultValue: ""),
    SchemaEntry(key: "DXMT_CAPTURE_FRAME", kind: .text, alwaysOn: false, quoted: false, defaultValue: ""),
    SchemaEntry(key: "DXMT_CAPTURE_EXECUTABLE", kind: .text, alwaysOn: false, quoted: false, defaultValue: ""),
    SchemaEntry(key: "DXMT_CONFIG_FILE", kind: .text, alwaysOn: false, quoted: false, defaultValue: ""),

    // DXMT_CONFIG itself is handled separately (dxmtConfig / dxmtConfigKeys below).
]

let schemaByKey: [String: SchemaEntry] = Dictionary(uniqueKeysWithValues: schema.map { ($0.key, $0) })

/// Env keys of D3DMetal's settings, which the Configurator no longer offers.
/// Lines for them are dropped from app.env instead of kept as unrecognised.
let retiredKeyPrefixes = ["D3DM_"]

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
    /// Whether a brand-new state (no app.env to seed from) packs this key
    /// into DXMT_CONFIG. Everything else stays off until someone enables it.
    var enabledByDefault = false
}

// Direct port of DXMT_CONFIG_KEYS.
let dxmtConfigKeys: [DXMTConfigEntry] = [
    DXMTConfigEntry(key: "d3d11.maxFeatureLevel", kind: .enumChoice, choices: ["9_1", "9_2", "9_3", "10_0", "10_1", "11_0", "11_1", "12_0", "12_1"], defaultValue: "11_1"),
    DXMTConfigEntry(key: "d3d11.preferredMaxFrameRate", kind: .int, choices: nil, defaultValue: "60"),
    // DXMT Tristate: auto follows the game's Present sync interval (vsync-updates builds only).
    DXMTConfigEntry(key: "d3d11.displaySync", kind: .enumChoice, choices: ["auto", "true", "false"], defaultValue: "true", enabledByDefault: true),
    DXMTConfigEntry(key: "d3d11.metalSpatialUpscaleFactor", kind: .float, choices: nil, defaultValue: "1.0"),
    DXMTConfigEntry(key: "d3d11.ignoreMapFlagNoWait", kind: .bool, choices: nil, defaultValue: "false"),
    DXMTConfigEntry(key: "d3d11.sampleNaNToZero", kind: .bool, choices: nil, defaultValue: "true", enabledByDefault: true),
    DXMTConfigEntry(key: "d3d11.defuseFma", kind: .bool, choices: nil, defaultValue: "false"),
    DXMTConfigEntry(key: "dxmt.shaderMetalVersion", kind: .enumChoice, choices: ["310", "320"], defaultValue: "310"),
    DXMTConfigEntry(key: "dxgi.customVendorId", kind: .text, choices: nil, defaultValue: ""),
    DXMTConfigEntry(key: "dxgi.customDeviceId", kind: .text, choices: nil, defaultValue: ""),
    DXMTConfigEntry(key: "dxgi.customDeviceDesc", kind: .text, choices: nil, defaultValue: ""),
    DXMTConfigEntry(key: "dxgi.forceSDR", kind: .bool, choices: nil, defaultValue: "false"),
    DXMTConfigEntry(key: "dxgi.handleAltTab", kind: .bool, choices: nil, defaultValue: "false"),
]

// EXE_PATH/EXE_RUN_DIR are owned by interactive_setup.py, never rendered as
// GUI fields; carried through every regeneration as opaque strings.
let passthroughKeys = ["EXE_PATH", "EXE_RUN_DIR"]

let pointerComment = "# Edit via Contents/Resources/Configurator.app — see it for descriptions and valid ranges."

// User-facing labels shown by default; the raw env-var/DXMT_CONFIG key is
// shown on hover (.help) instead, so this file stays the single place that
// needs updating when a key's wording changes.
let friendlyLabels: [String: String] = [
    "MTL_HUD_ENABLED": "Metal Performance HUD",
    "WINEMSYNC": "Msync",
    "WINEESYNC": "Esync",
    "ROSETTA_ADVERTISE_AVX": "Advertise AVX Under Rosetta",
    "WINEDEBUG": "Wine Debug Channels",
    "DEFAULT_GAME_ARGS": "Launch Arguments",
    "GAMMA_RETINA_MODE": "Retina Display Mode",
    "GAMMA_RETINA_LOGPIXELS": "Retina DPI Override",

    "DXMT_METALFX_SPATIAL_SWAPCHAIN": "MetalFX Spatial Upscaling",
    "DXMT_ENABLE_NVEXT": "DLSS Support (NVAPI)",
    "DXMT_LOG_LEVEL": "Log Level",
    "DXMT_LOG_PATH": "Log File Path",
    "DXMT_SHADER_CACHE": "Shader Cache",
    "DXMT_SHADER_CACHE_PATH": "Shader Cache Path",
    "DXMT_CAPTURE_FRAME": "Frame Capture Trigger",
    "DXMT_CAPTURE_EXECUTABLE": "Metal Frame Capture Tool",
    "DXMT_CONFIG_FILE": "DXMT Config File Override",

    "d3d11.maxFeatureLevel": "Max DirectX Feature Level",
    "d3d11.preferredMaxFrameRate": "Preferred Max Frame Rate",
    "d3d11.displaySync": "Metal Display Sync (V-Sync)",
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

/// A row in the window: an app.env key or a DXMT_CONFIG sub-key.
enum SettingRef: Hashable {
    case env(String)
    case dxmt(String)

    var key: String {
        switch self {
        case .env(let key), .dxmt(let key): key
        }
    }
}

struct SettingGroup {
    let title: String
    let settings: [SettingRef]
    var help: String? = nil
}

/// Always-visible cards, in window order: settings a player actually changes.
let mainGroups: [SettingGroup] = [
    SettingGroup(title: "Display & Performance", settings: [
        .dxmt("d3d11.displaySync"),
        .env("DXMT_ENABLE_NVEXT"),
        .env("DXMT_METALFX_SPATIAL_SWAPCHAIN"),
        .dxmt("d3d11.metalSpatialUpscaleFactor"),
        .env("MTL_HUD_ENABLED"),
    ]),
    SettingGroup(title: "Rendering Fixes", settings: [
        .dxmt("d3d11.sampleNaNToZero"),
        .dxmt("d3d11.defuseFma"),
    ], help: "\"Default\" leaves the option out of DXMT_CONFIG, so DXMT uses its own built-in default."),
]

/// Subgroups of the collapsed Advanced section, in window order.
let advancedGroups: [SettingGroup] = [
    SettingGroup(title: "Game", settings: [
        .env("DEFAULT_GAME_ARGS"),
    ]),
    SettingGroup(title: "Display", settings: [
        .env("GAMMA_RETINA_MODE"),
        .env("GAMMA_RETINA_LOGPIXELS"),
        .dxmt("d3d11.preferredMaxFrameRate"),
    ]),
    SettingGroup(title: "Compatibility", settings: [
        .env("WINEMSYNC"),
        .env("WINEESYNC"),
        .env("ROSETTA_ADVERTISE_AVX"),
        .dxmt("d3d11.maxFeatureLevel"),
        .dxmt("dxmt.shaderMetalVersion"),
        .dxmt("d3d11.ignoreMapFlagNoWait"),
        .dxmt("dxgi.forceSDR"),
        .dxmt("dxgi.handleAltTab"),
    ]),
    SettingGroup(title: "GPU Identity", settings: [
        .dxmt("dxgi.customVendorId"),
        .dxmt("dxgi.customDeviceId"),
        .dxmt("dxgi.customDeviceDesc"),
    ]),
    SettingGroup(title: "Shader Cache", settings: [
        .env("DXMT_SHADER_CACHE"),
        .env("DXMT_SHADER_CACHE_PATH"),
    ]),
    SettingGroup(title: "Debugging & Capture", settings: [
        .env("WINEDEBUG"),
        .env("DXMT_LOG_LEVEL"),
        .env("DXMT_LOG_PATH"),
        .env("DXMT_CAPTURE_FRAME"),
        .env("DXMT_CAPTURE_EXECUTABLE"),
        .env("DXMT_CONFIG_FILE"),
    ]),
]

/// Rows shown only while the named app.env switch is on.
let shownOnlyWhenOn: [String: String] = [
    "GAMMA_RETINA_LOGPIXELS": "GAMMA_RETINA_MODE",
    "d3d11.metalSpatialUpscaleFactor": "DXMT_METALFX_SPATIAL_SWAPCHAIN",
]

let dxmtConfigByKey: [String: DXMTConfigEntry] = Dictionary(uniqueKeysWithValues: dxmtConfigKeys.map { ($0.key, $0) })

func friendlyLabel(for key: String) -> String {
    friendlyLabels[key] ?? key
}
