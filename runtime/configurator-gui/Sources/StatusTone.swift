import SwiftUI

enum StatusTone {
    case success
    case warning
    case error
    case secondary

    var color: Color {
        switch self {
        case .success: return .green
        case .warning: return .yellow
        case .error: return .red
        case .secondary: return .secondary
        }
    }
}
