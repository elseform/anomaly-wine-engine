import SwiftUI

/// One app.env row: a switch for on/off keys, otherwise a text field,
/// with a checkbox in front when the key is optional. Rows keep their own
/// editing state, seeded from the model when the row is created.
struct SchemaRow: View {
    let model: ConfiguratorModel
    let entry: SchemaEntry

    @State private var text: String
    @State private var enabled: Bool
    @State private var isOn: Bool

    init(model: ConfiguratorModel, entry: SchemaEntry) {
        self.model = model
        self.entry = entry
        let current = model.varEntry(for: entry)
        let value = current.value.trimmingCharacters(in: .whitespaces)
        _text = State(initialValue: current.value)
        _enabled = State(initialValue: current.enabled)
        _isOn = State(initialValue: value == (entry.kind == .retina ? "Y" : "1"))
    }

    var body: some View {
        switch entry.kind {
        case .retina:
            Toggle(isOn: $isOn) { SettingLabel(key: entry.key) }
                .onChange(of: isOn) { _, on in
                    model.setVar(entry.key, enabled: true, value: on ? "Y" : "N")
                }

        case .bool where entry.alwaysOn:
            Toggle(isOn: $isOn) { SettingLabel(key: entry.key) }
                .onChange(of: isOn) { _, on in
                    model.setVar(entry.key, enabled: true, value: on ? "1" : "0")
                }

        default:
            LabeledContent {
                HStack {
                    if !entry.alwaysOn {
                        Toggle("Use", isOn: $enabled)
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .onChange(of: enabled) { _, enabled in
                                model.setVar(entry.key, enabled: enabled, value: text)
                            }
                    }
                    CommitTextField(text: $text, isEnabled: entry.alwaysOn || enabled) {
                        model.setVar(entry.key, enabled: entry.alwaysOn || enabled, value: text)
                    }
                }
            } label: {
                SettingLabel(key: entry.key)
            }
        }
    }
}

/// One DXMT_CONFIG row. Booleans and fixed choices are a picker whose
/// "Default" leaves the key out of DXMT_CONFIG; numbers and text are a
/// checkbox plus field.
struct DXMTConfigRow: View {
    let model: ConfiguratorModel
    let entry: DXMTConfigEntry

    @State private var included: Bool
    @State private var text: String
    @State private var choice: String?

    init(model: ConfiguratorModel, entry: DXMTConfigEntry) {
        self.model = model
        self.entry = entry
        let current = model.dxmtEntry(for: entry)
        let value = entry.kind == .bool ? current.value.lowercased() : current.value
        _included = State(initialValue: current.enabled)
        _text = State(initialValue: value)
        _choice = State(initialValue: current.enabled ? value : nil)
    }

    private var options: [String]? {
        switch entry.kind {
        case .bool: ["true", "false"]
        case .enumChoice: entry.choices
        default: nil
        }
    }

    var body: some View {
        if let options {
            Picker(selection: $choice) {
                Text("Default").tag(String?.none)
                ForEach(options, id: \.self) { option in
                    Text(displayName(for: option)).tag(String?.some(option))
                }
            } label: {
                SettingLabel(key: entry.key)
            }
            .onChange(of: choice) { _, newValue in
                if let newValue {
                    text = newValue
                    model.setDXMT(entry.key, enabled: true, value: newValue)
                } else {
                    model.setDXMT(entry.key, enabled: false, value: text)
                }
            }
        } else {
            LabeledContent {
                HStack {
                    Toggle("Use", isOn: $included)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .onChange(of: included) { _, enabled in
                            model.setDXMT(entry.key, enabled: enabled, value: text)
                        }
                    CommitTextField(text: $text, isEnabled: included) {
                        model.setDXMT(entry.key, enabled: included, value: text)
                    }
                }
            } label: {
                SettingLabel(key: entry.key)
            }
        }
    }

    private func displayName(for option: String) -> String {
        switch option {
        case "true": "On"
        case "false": "Off"
        case "auto": "Auto"
        default: option
        }
    }
}

/// Renders an app.env or DXMT_CONFIG row, hidden while its parent switch is off.
struct SettingRow: View {
    let model: ConfiguratorModel
    let setting: SettingRef

    var body: some View {
        if model.isVisible(setting) {
            switch setting {
            case .env(let key):
                if let entry = schemaByKey[key] {
                    SchemaRow(model: model, entry: entry)
                }
            case .dxmt(let key):
                if let entry = dxmtConfigByKey[key] {
                    DXMTConfigRow(model: model, entry: entry)
                }
            }
        }
    }
}

struct ConfiguratorView: View {
    @State private var model = ConfiguratorModel()
    @AppStorage("advancedExpanded") private var showAdvanced = false
    @State private var confirmReset = false
    /// Height of everything in the form, so the window can match it.
    @State private var contentHeight: CGFloat = Layout.initialHeight

    var body: some View {
        Form {
            if let error = model.loadError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(StatusTone.error.color)
                }
            }

            Group {
                ForEach(mainGroups, id: \.title) { group in
                    section(for: group)
                }

                advancedToggle

                if showAdvanced {
                    ForEach(advancedGroups, id: \.title) { group in
                        section(for: group)
                    }
                }
            }
            .id(model.revision)
            .disabled(!model.canEdit)

            Section {
                Button("Reset to Defaults…", role: .destructive) {
                    confirmReset = true
                }
                .disabled(!model.canEdit)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset all settings to their defaults?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive, action: model.resetToDefaults)
        } message: {
            Text("Every setting, including launch arguments, goes back to what a new install starts with.")
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom
        } action: { _, height in
            contentHeight = height
        }
        // The window follows this size (.windowResizability(.contentSize));
        // past the screen's height the form scrolls instead.
        .frame(width: Layout.windowWidth, height: min(contentHeight, Layout.maximumHeight))
    }

    private var advancedToggle: some View {
        Section {
            Button {
                showAdvanced.toggle()
            } label: {
                HStack {
                    Text(showAdvanced ? "Hide Advanced Settings" : "Show Advanced Settings")
                    Spacer()
                    let changed = model.advancedChangedCount
                    if changed > 0 {
                        Text("\(changed) changed")
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        } footer: {
            Text("For troubleshooting. Most players never need these.")
        }
    }

    private func section(for group: SettingGroup) -> some View {
        Section {
            ForEach(group.settings, id: \.self) { setting in
                SettingRow(model: model, setting: setting)
            }
        } header: {
            Text(group.title)
        } footer: {
            if let help = group.help {
                Text(help)
            }
        }
    }
}
