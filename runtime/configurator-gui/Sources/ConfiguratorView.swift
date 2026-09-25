import SwiftUI

struct CommitTextField: View {
    @Binding var text: String
    var isEnabled = true
    var onCommit: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .disabled(!isEnabled)
            .focused($isFocused)
            .onSubmit(onCommit)
            .onChange(of: isFocused) { _, focused in
                if !focused { onCommit() }
            }
    }
}

/// One schema row: retina toggle / always-on bool toggle /
/// always-on text field / optional (checkbox-gated) text field. Mirrors
/// configurator.py's ConfiguratorWindow._build_row branch-for-branch.
struct SchemaRow: View {
    @ObservedObject var model: ConfiguratorModel
    let entry: SchemaEntry

    @State private var text: String = ""
    @State private var rowEnabled: Bool = true

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(friendlyLabel(for: entry.key))
                .frame(width: 260, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(entry.key)

            controls
        }
        .onAppear(perform: sync)
    }

    @ViewBuilder
    private var controls: some View {
        switch entry.kind {
        case .retina:
            Toggle(isOn: retinaBinding) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()

        case .bool where entry.alwaysOn:
            Toggle(isOn: boolBinding) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()

        default:
            HStack {
                if !entry.alwaysOn {
                    Toggle(isOn: $rowEnabled) { EmptyView() }
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .onChange(of: rowEnabled) { _, enabled in
                            model.setVar(entry.key, enabled: enabled, value: text)
                        }
                }
                CommitTextField(text: $text, isEnabled: entry.alwaysOn || rowEnabled) {
                    model.setVar(entry.key, enabled: entry.alwaysOn || rowEnabled, value: text)
                }
            }
        }
    }

    private func sync() {
        let current = model.varEntry(for: entry)
        text = current.value
        rowEnabled = current.enabled
    }

    private var retinaBinding: Binding<Bool> {
        Binding(
            get: { model.varEntry(for: entry).value.trimmingCharacters(in: .whitespaces) == "Y" },
            set: { model.setVar(entry.key, enabled: true, value: $0 ? "Y" : "N") }
        )
    }

    private var boolBinding: Binding<Bool> {
        Binding(
            get: { model.varEntry(for: entry).value.trimmingCharacters(in: .whitespaces) == "1" },
            set: { model.setVar(entry.key, enabled: true, value: $0 ? "1" : "0") }
        )
    }
}

/// One DXMT_CONFIG sub-key row: tri-state for bool (enabled+true / enabled+false
/// / not included), checkbox + field for everything else. Mirrors
/// configurator.py's _build_dxmt_config_form.
struct DXMTConfigRow: View {
    @ObservedObject var model: ConfiguratorModel
    let entry: DXMTConfigEntry

    @State private var included = false
    @State private var text = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(friendlyLabel(for: entry.key))
                .frame(width: 260, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(entry.key)

            if entry.kind == .bool {
                Picker("", selection: triStateBinding) {
                    Text("Default").tag(Optional<Bool>.none)
                    Text("false").tag(Optional(false))
                    Text("true").tag(Optional(true))
                }
                .labelsHidden()
                .frame(width: 160)
            } else {
                HStack {
                    Toggle(isOn: $included) { EmptyView() }
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .onChange(of: included) { _, enabled in
                            model.setDXMT(entry.key, enabled: enabled, value: text)
                        }
                    fieldControl
                }
            }
        }
        .onAppear(perform: sync)
    }

    @ViewBuilder
    private var fieldControl: some View {
        if entry.kind == .enumChoice, let choices = entry.choices {
            Picker("", selection: Binding(
                get: { text },
                set: { newValue in
                    text = newValue
                    model.setDXMT(entry.key, enabled: included, value: newValue)
                }
            )) {
                ForEach(choices, id: \.self) { choice in
                    Text(choice).tag(choice)
                }
            }
            .labelsHidden()
            .disabled(!included)
            .frame(width: 160)
        } else {
            CommitTextField(text: $text, isEnabled: included) {
                model.setDXMT(entry.key, enabled: included, value: text)
            }
        }
    }

    private func sync() {
        let current = model.dxmtEntry(for: entry)
        included = current.enabled
        text = current.value
    }

    private var triStateBinding: Binding<Bool?> {
        Binding(
            get: { included ? (text.lowercased() == "true") : nil },
            set: { newValue in
                switch newValue {
                case nil:
                    included = false
                    text = "false"
                case .some(let boolValue):
                    included = true
                    text = boolValue ? "true" : "false"
                }
                model.setDXMT(entry.key, enabled: included, value: text)
            }
        )
    }
}

/// Renders an app.env or DXMT_CONFIG row, hidden while its parent switch is off.
struct SettingRow: View {
    @ObservedObject var model: ConfiguratorModel
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
    @StateObject private var model = ConfiguratorModel()
    @AppStorage("advancedExpanded") private var advancedExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.rowSpacing * 2) {
                if let error = model.loadError {
                    WizardCard {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(StatusTone.error.color)
                    }
                }

                settingsCards
                    .disabled(!model.canEdit)
            }
            .padding(.horizontal, Layout.contentHorizontalPadding)
            .padding(.vertical, Layout.contentVerticalPadding)
        }
        .frame(minWidth: Layout.windowMinimumWidth, minHeight: Layout.windowMinimumHeight)
        .background(WindowMinimumSize(width: Layout.windowMinimumWidth, height: Layout.windowMinimumHeight))
    }

    @ViewBuilder
    private var settingsCards: some View {
        ForEach(mainGroups, id: \.title) { group in
            WizardCard {
                VStack(alignment: .leading, spacing: Layout.cardContentSpacing) {
                    HStack(spacing: 6) {
                        SectionTitle(title: group.title)
                        if let help = group.help {
                            HelpTip(text: help)
                        }
                    }
                    rows(for: group)
                }
            }
        }

        WizardCard {
            DisclosureGroup(isExpanded: $advancedExpanded) {
                VStack(alignment: .leading, spacing: Layout.cardContentSpacing * 2) {
                    ForEach(advancedGroups, id: \.title) { group in
                        VStack(alignment: .leading, spacing: Layout.cardContentSpacing) {
                            Text(group.title)
                                .font(.headline)
                            rows(for: group)
                        }
                    }
                }
                .padding(.top, Layout.cardContentSpacing)
            } label: {
                HStack(spacing: 8) {
                    SectionTitle(title: "Advanced")
                    let changed = model.advancedChangedCount
                    if changed > 0 {
                        Text("\(changed) changed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func rows(for group: SettingGroup) -> some View {
        ForEach(group.settings, id: \.self) { setting in
            SettingRow(model: model, setting: setting)
        }
    }
}
