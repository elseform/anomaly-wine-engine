import AppKit

enum Layout {
    static let windowWidth: CGFloat = 620
    static let initialHeight: CGFloat = 600
    static let fieldWidth: CGFloat = 200

    /// Tallest the window gets before the form scrolls: the screen's
    /// usable height, less room for the title bar.
    @MainActor
    static var maximumHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 900) - 60
    }
}
