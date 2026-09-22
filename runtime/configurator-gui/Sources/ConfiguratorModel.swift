import Foundation

@MainActor
final class ConfiguratorModel: ObservableObject {
    @Published var state: ConfiguratorState
    let configFile: String
    /// True when the engine ships only DXMT, or the installer asked for it.
    let dxmtOnly: Bool
    let loadError: String?

    init(install: InstallLayout = .current()) {
        let d3dmetalAvailable = install.d3dmetalAvailable
        if let paths = PathsConfig.load(install: install) {
            configFile = paths.configFile
            dxmtOnly = paths.dxmtOnly || !d3dmetalAvailable
            loadError = nil
            state = loadState(configFile: paths.configFile, legacyStateFile: paths.stateFile)
        } else {
            configFile = ""
            dxmtOnly = !d3dmetalAvailable
            loadError = "Could not find this install's app.env. The Configurator must be opened from inside an installed GAMMA wrapper; settings cannot be saved."
            state = defaultState()
        }
        if dxmtOnly, state.vars["GAMMA_GRAPHICS_BACKEND"]?.value != "dxmt" {
            state.vars["GAMMA_GRAPHICS_BACKEND"] = VarEntry(enabled: true, value: "dxmt")
            persist()
        }
    }

    var canEdit: Bool {
        loadError == nil
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
        state.dxmtConfig[entry.key] ?? VarEntry(enabled: entry.enabledByDefault, value: entry.defaultValue)
    }

    func setDXMT(_ key: String, enabled: Bool, value: String) {
        state.dxmtConfig[key] = VarEntry(enabled: enabled, value: value)
        persist()
    }

    private func persist() {
        guard !configFile.isEmpty else { return }
        saveEnv(&state, configFile: configFile)
    }
}
