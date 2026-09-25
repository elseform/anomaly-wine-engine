import SwiftUI

/// A setting's name with its one-line description underneath. The raw
/// env-var/DXMT_CONFIG key is on hover.
struct SettingLabel: View {
    let key: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(friendlyLabel(for: key))
            if let description = friendlyDescription(for: key) {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .help(key)
    }
}

/// A text field that saves on Return and when it loses focus, not on every
/// keystroke.
struct CommitTextField: View {
    @Binding var text: String
    var isEnabled = true
    var onCommit: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $text)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .frame(width: Layout.fieldWidth)
            .disabled(!isEnabled)
            .focused($isFocused)
            .onSubmit(onCommit)
            .onChange(of: isFocused) { _, focused in
                if !focused { onCommit() }
            }
    }
}
