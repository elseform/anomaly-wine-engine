import Foundation

@MainActor
final class ConfiguratorModel: ObservableObject {
    @Published var state: ConfiguratorState
    let configFile: String
    let stateFile: String
    let loadError: String?

    init() {
        if let paths = PathsConfig.load() {
            configFile = paths.configFile
            stateFile = paths.stateFile
            loadError = nil
            state = loadOrBootstrapState(configFile: paths.configFile, stateFile: paths.stateFile)
        } else {
            configFile = ""
            stateFile = ""
            loadError = "Could not find paths.json in the app bundle — this Configurator was not launched from an installed GAMMA.app."
            state = defaultState()
        }
    }

    var backend: String {
        state.vars["GAMMA_GRAPHICS_BACKEND"]?.value ?? "dxmt"
    }

    func varEntry(for entry: SchemaEntry) -> VarEntry {
        state.vars[entry.key] ?? VarEntry(enabled: entry.alwaysOn, value: entry.defaultValue)
    }

    func setVar(_ key: String, enabled: Bool, value: String) {
        state.vars[key] = VarEntry(enabled: enabled, value: value)
        persist()
    }

    func dxmtEntry(for entry: DXMTConfigEntry) -> VarEntry {
        state.dxmtConfig[entry.key] ?? VarEntry(enabled: false, value: entry.defaultValue)
    }

    func setDXMT(_ key: String, enabled: Bool, value: String) {
        state.dxmtConfig[key] = VarEntry(enabled: enabled, value: value)
        persist()
    }

    private func persist() {
        guard !configFile.isEmpty else { return }
        saveStateAndEnv(&state, configFile: configFile, stateFile: stateFile)
    }
}
