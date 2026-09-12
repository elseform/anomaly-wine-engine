import SwiftUI
import AppKit

struct WindowMinimumSize: NSViewRepresentable {
    let width: CGFloat
    let height: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            applySizing(to: view.window)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            applySizing(to: view.window)
        }
    }

    private func applySizing(to window: NSWindow?) {
        guard let window else { return }
        window.minSize = NSSize(width: width, height: height)
    }
}

enum Layout {
    static let windowDefaultWidth: CGFloat = 620
    static let windowDefaultHeight: CGFloat = 700
    static let windowMinimumWidth: CGFloat = 520
    static let windowMinimumHeight: CGFloat = 480
    static let contentHorizontalPadding: CGFloat = 20
    static let contentVerticalPadding: CGFloat = 16
    static let cardPanelHorizontalPadding: CGFloat = 14
    static let cardPanelVerticalPadding: CGFloat = 12
    static let cardContentSpacing: CGFloat = 8
    static let rowSpacing: CGFloat = 8
}
