import SwiftUI
import AppKit

typealias UIState<Value> = SwiftUI.State<Value>
enum ReaderTheme {
    static let canvas = Color(nsColor: .textBackgroundColor)
    static let sidebar = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let border = Color.primary.opacity(0.08)
    static let body = Font.system(size: 14)
    static func speaker(_ number: Int?) -> Color {
        switch (number ?? -1) % 4 {
        case 0: return Color(nsColor: tint)
        case 1: return Color(nsColor: .systemIndigo)
        case 2: return Color(nsColor: .systemBrown)
        case 3: return Color(nsColor: .systemPurple)
        default: return .secondary
        }
    }
    static let tint = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.38, green: 0.76, blue: 0.67, alpha: 1)
            : NSColor(srgbRed: 0.12, green: 0.43, blue: 0.40, alpha: 1)
    }
}
let accent = Color(nsColor: ReaderTheme.tint)
