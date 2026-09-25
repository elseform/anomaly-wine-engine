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

// User-facing labels and one-line descriptions shown by default; the raw
// env-var/DXMT_CONFIG key is shown on hover (.help) instead, so this file
// stays the single place that needs updating when a key's wording changes.
let friendlyLabels: [String: String] = [
    "MTL_HUD_ENABLED": "Performance Overlay",
    "WINEMSYNC": "Msync",
    "WINEESYNC": "Esync",
    "ROSETTA_ADVERTISE_AVX": "Advertise AVX Under Rosetta",
    "WINEDEBUG": "Wine Debug Channels",
    "DEFAULT_GAME_ARGS": "Launch Arguments",
    "GAMMA_RETINA_MODE": "Retina Resolution",
    "GAMMA_RETINA_LOGPIXELS": "Retina DPI Override",

    "DXMT_METALFX_SPATIAL_SWAPCHAIN": "MetalFX Upscaling",
    "DXMT_ENABLE_NVEXT": "DLSS Support",
    "DXMT_LOG_LEVEL": "Log Level",
    "DXMT_LOG_PATH": "Log File Path",
    "DXMT_SHADER_CACHE": "Shader Cache",
    "DXMT_SHADER_CACHE_PATH": "Shader Cache Path",
    "DXMT_CAPTURE_FRAME": "Frame Capture Trigger",
    "DXMT_CAPTURE_EXECUTABLE": "Metal Frame Capture Tool",
    "DXMT_CONFIG_FILE": "DXMT Config File Override",

    "d3d11.maxFeatureLevel": "Max DirectX Feature Level",
    "d3d11.preferredMaxFrameRate": "Preferred Max Frame Rate",
    "d3d11.displaySync": "V-Sync",
    "d3d11.metalSpatialUpscaleFactor": "Upscale Factor",
    "d3d11.ignoreMapFlagNoWait": "Ignore Map No-Wait Flag",
    "d3d11.sampleNaNToZero": "Clamp NaN Samples To Zero",
    "d3d11.defuseFma": "Disable Fused Multiply-Add",
    "dxmt.shaderMetalVersion": "Metal Shading Language Version",
    "dxgi.customVendorId": "Custom Vendor ID",
    "dxgi.customDeviceId": "Custom Device ID",
    "dxgi.customDeviceDesc": "Custom Device Description",
    "dxgi.forceSDR": "Force SDR Output",
    "dxgi.handleAltTab": "Handle Alt+Tab",
]

let friendlyDescriptions: [String: String] = [
    "MTL_HUD_ENABLED": "Shows Apple's Metal HUD with frame rate and GPU stats.",
    "WINEMSYNC": "Faster thread synchronization in Wine. Turn off only to troubleshoot.",
    "WINEESYNC": "Fallback thread synchronization in Wine. Turn off only to troubleshoot.",
    "ROSETTA_ADVERTISE_AVX": "Tells the game the CPU supports AVX under Rosetta.",
    "WINEDEBUG": "Which Wine debug messages are logged. \"-all\" logs none.",
    "DEFAULT_GAME_ARGS": "Extra arguments passed to the program the app launches.",
    "GAMMA_RETINA_MODE": "Lets the game use your display's full Retina resolution.",
    "GAMMA_RETINA_LOGPIXELS": "Windows DPI to use in Retina mode.",

    "DXMT_METALFX_SPATIAL_SWAPCHAIN": "Upscales the final image with Apple MetalFX.",
    "DXMT_ENABLE_NVEXT": "Needed for the game's DLSS options.",
    "DXMT_LOG_LEVEL": "How much DXMT writes to its log.",
    "DXMT_LOG_PATH": "Folder for DXMT log files. \"none\" writes no log files.",
    "DXMT_SHADER_CACHE": "Set to 0 to turn off DXMT's shader cache.",
    "DXMT_SHADER_CACHE_PATH": "Absolute path of the folder for the shader cache.",
    "DXMT_CAPTURE_FRAME": "Captures this frame number automatically.",
    "DXMT_CAPTURE_EXECUTABLE": "Executable name, without extension, to allow Metal frame capture for. F10 captures a frame.",
    "DXMT_CONFIG_FILE": "Path of a dxmt.conf file to read DXMT options from.",

    "d3d11.maxFeatureLevel": "Highest DirectX 11 feature level reported to the game.",
    "d3d11.preferredMaxFrameRate": "Frame rate cap paced by Metal. Use a factor of your display's refresh rate, like 30, 60 or 120.",
    "d3d11.displaySync": "Syncs frames to the display. Auto follows the game's own V-Sync setting.",
    "d3d11.metalSpatialUpscaleFactor": "Output size multiplier, above 1.0. For example, 1.33 turns 1080p into 1440p.",
    "d3d11.ignoreMapFlagNoWait": "Workaround for games that mishandle a D3D11 no-wait map flag.",
    "d3d11.sampleNaNToZero": "Reads invalid (NaN) texture samples as zero.",
    "d3d11.defuseFma": "Compiles shaders without fused multiply-add.",
    "dxmt.shaderMetalVersion": "310 is Metal 3.1 (macOS 14+), 320 is Metal 3.2 (macOS 15+). Default uses the newest supported.",
    "dxgi.customVendorId": "GPU vendor ID reported to the game.",
    "dxgi.customDeviceId": "GPU device ID reported to the game.",
    "dxgi.customDeviceDesc": "GPU name reported to the game.",
    "dxgi.forceSDR": "Never uses HDR output.",
    "dxgi.handleAltTab": "Lets DXMT handle Cmd+Tab in exclusive fullscreen.",
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

/// Always-visible sections, in window order: settings a player actually changes.
let mainGroups: [SettingGroup] = [
    SettingGroup(title: "Display & Performance", settings: [
        .dxmt("d3d11.displaySync"),
        .env("DXMT_ENABLE_NVEXT"),
        .env("DXMT_METALFX_SPATIAL_SWAPCHAIN"),
        .dxmt("d3d11.metalSpatialUpscaleFactor"),
        .env("MTL_HUD_ENABLED"),
    ]),
    SettingGroup(title: "Game", settings: [
        .env("DEFAULT_GAME_ARGS"),
    ]),
    SettingGroup(title: "Rendering Fixes", settings: [
        .dxmt("d3d11.sampleNaNToZero"),
        .dxmt("d3d11.defuseFma"),
    ], help: "Default leaves the option to DXMT's own built-in default."),
]

/// Sections shown under Advanced, in window order.
let advancedGroups: [SettingGroup] = [
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

func friendlyDescription(for key: String) -> String? {
    friendlyDescriptions[key]
}
