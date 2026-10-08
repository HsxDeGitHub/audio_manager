import SwiftUI
import AppKit

typealias UIState<Value> = SwiftUI.State<Value>
enum ReaderTheme {
    static let tint = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.38, green: 0.76, blue: 0.67, alpha: 1)
            : NSColor(srgbRed: 0.12, green: 0.43, blue: 0.40, alpha: 1)
    }
}
let accent = Color(nsColor: ReaderTheme.tint)
