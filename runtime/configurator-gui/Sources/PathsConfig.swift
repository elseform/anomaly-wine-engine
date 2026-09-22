import Foundation

// Where this install's app.env lives, and which graphics backends its engine
// actually ships.
//
// The Configurator is nested in the wrapper as
// <App>.app/Contents/Resources/Configurator.app, next to the engine at
// <App>.app/Contents/Resources/engine. gamma-setup-tool's interactive_setup.py
// writes the paths file at install time. Paths are resolved in this order:
//   1. Contents/Resources/paths.json inside this Configurator bundle (written
//      by installers from before configurator-paths.json existed);
//   2. <App>.app/Contents/Resources/configurator-paths.json, outside this
//      bundle, so replacing Configurator.app cannot lose it;
//   3. ~/Library/Application Support/<App name>/app.env, the location
//      interactive_setup.py always uses, if that file exists.
struct PathsConfig: Decodable {
    let configFile: String
    /// Only read to recover values from a pre-app.env-only install.
    let stateFile: String?
    let dxmtOnly: Bool

    enum CodingKeys: String, CodingKey {
        case configFile = "configFile"
        case stateFile = "stateFile"
        case dxmtOnly = "dxmtOnly"
    }

    init(configFile: String, stateFile: String?, dxmtOnly: Bool) {
        self.configFile = configFile
        self.stateFile = stateFile
        self.dxmtOnly = dxmtOnly
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        configFile = try container.decode(String.self, forKey: .configFile)
        stateFile = try container.decodeIfPresent(String.self, forKey: .stateFile)
        dxmtOnly = try container.decodeIfPresent(Bool.self, forKey: .dxmtOnly) ?? false
    }

    static func load(install: InstallLayout) -> PathsConfig? {
        var candidates: [URL] = []
        if let inBundle = Bundle.main.url(forResource: "paths", withExtension: "json") {
            candidates.append(inBundle)
        }
        if let wrapper = install.wrapperURL {
            candidates.append(wrapper.appendingPathComponent("Contents/Resources/configurator-paths.json"))
        }
        for url in candidates {
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode(PathsConfig.self, from: data) {
                return decoded
            }
        }
        return derivedDefault(install: install)
    }

    private static func derivedDefault(install: InstallLayout) -> PathsConfig? {
        guard let wrapper = install.wrapperURL else { return nil }
        let appName = wrapper.deletingPathExtension().lastPathComponent
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = support.appendingPathComponent(appName, isDirectory: true)
        let configFile = directory.appendingPathComponent("app.env").path
        guard FileManager.default.fileExists(atPath: configFile) else { return nil }
        return PathsConfig(
            configFile: configFile,
            stateFile: directory.appendingPathComponent("configurator-state.json").path,
            dxmtOnly: false
        )
    }
}

/// The wrapper and engine this Configurator belongs to, derived from where the
/// bundle sits on disk.
struct InstallLayout {
    let wrapperURL: URL?
    let engineURL: URL?

    static func current(bundleURL: URL = Bundle.main.bundleURL) -> InstallLayout {
        let resources = bundleURL.deletingLastPathComponent()
        let contents = resources.deletingLastPathComponent()
        let wrapper = contents.deletingLastPathComponent()
        if resources.lastPathComponent == "Resources",
           contents.lastPathComponent == "Contents",
           wrapper.pathExtension == "app" {
            return InstallLayout(wrapperURL: wrapper, engineURL: resources.appendingPathComponent("engine"))
        }
        // The copy the engine ships at <engine>/share/gamma/Configurator.app.
        let gamma = bundleURL.deletingLastPathComponent()
        let share = gamma.deletingLastPathComponent()
        if gamma.lastPathComponent == "gamma", share.lastPathComponent == "share" {
            return InstallLayout(wrapperURL: nil, engineURL: share.deletingLastPathComponent())
        }
        return InstallLayout(wrapperURL: nil, engineURL: nil)
    }

    /// D3DMetal is offered only when the engine ships it. This is the same
    /// directory pack-engine-artifact.sh tests to decide a DXMT-only build and
    /// that cxcompatdb validates before selecting the d3dmetal backend.
    var d3dmetalAvailable: Bool {
        guard let engineURL else { return false }
        let d3d11 = engineURL.appendingPathComponent("lib64/apple_gptk/wine/x86_64-windows/d3d11.dll")
        return FileManager.default.fileExists(atPath: d3d11.path)
    }
}
