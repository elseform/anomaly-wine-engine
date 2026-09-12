import SwiftUI

struct WizardCard<Content: View>: View {
    var horizontalPadding = Layout.cardPanelHorizontalPadding
    var verticalPadding = Layout.cardPanelVerticalPadding
    @ViewBuilder var content: () -> Content

    var body: some View {
        GroupBox {
            content()
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct SectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.title3.weight(.semibold))
    }
}

struct HelpTip: View {
    let text: String
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(text)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            Text(text)
                .font(.body)
                .frame(width: 260, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
        }
    }
}
