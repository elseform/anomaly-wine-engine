import Foundation

// Where this install's app.env lives.
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

    enum CodingKeys: String, CodingKey {
        case configFile = "configFile"
        case stateFile = "stateFile"
    }

    init(configFile: String, stateFile: String?) {
        self.configFile = configFile
        self.stateFile = stateFile
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        configFile = try container.decode(String.self, forKey: .configFile)
        stateFile = try container.decodeIfPresent(String.self, forKey: .stateFile)
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
            stateFile: directory.appendingPathComponent("configurator-state.json").path
        )
    }
}

/// The wrapper this Configurator belongs to, derived from where the bundle
/// sits on disk. nil for the copy the engine ships at
/// <engine>/share/gamma/Configurator.app, or anywhere else.
struct InstallLayout {
    let wrapperURL: URL?

    static func current(bundleURL: URL = Bundle.main.bundleURL) -> InstallLayout {
        let resources = bundleURL.deletingLastPathComponent()
        let contents = resources.deletingLastPathComponent()
        let wrapper = contents.deletingLastPathComponent()
        if resources.lastPathComponent == "Resources",
           contents.lastPathComponent == "Contents",
           wrapper.pathExtension == "app" {
            return InstallLayout(wrapperURL: wrapper)
        }
        return InstallLayout(wrapperURL: nil)
    }
}
