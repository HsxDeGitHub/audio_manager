import AppKit
import SwiftUI

/// 选区在转移输入焦点前取快照，浮层和右键菜单使用同一入口。
class QuoteSelectionTextView: NSTextView {
    var onQuote: ((NSRange) -> Void)?
    private var quotePopover: NSPopover?
    // NSTextView 在 mouseDown 的内部追踪循环中消费 mouseUp；选区在 super 返回后才稳定。
    override func mouseDown(with event: NSEvent) { dismissQuote(); super.mouseDown(with: event); showQuote() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { dismissQuote() } }
    func dismissQuote() { quotePopover?.close(); quotePopover = nil }
    func addQuoteItem(to menu: NSMenu) {
        guard selectedRange().length > 0, onQuote != nil else { return }
        let item = NSMenuItem(title: "添加到对话", action: #selector(quoteSelection(_:)), keyEquivalent: "")
        item.target = self; menu.insertItem(item, at: 0); menu.insertItem(.separator(), at: 1)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu(); addQuoteItem(to: menu); return menu
    }
    @objc private func quoteSelection(_ sender: Any?) { let range = selectedRange(); dismissQuote(); if range.length > 0 { onQuote?(range) } }
    func showQuote() {
        dismissQuote()
        let range = selectedRange()
        guard range.length > 0, onQuote != nil, window != nil, let layout = layoutManager, let container = textContainer else { return }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += textContainerOrigin.x; rect.origin.y += textContainerOrigin.y
        rect = rect.intersection(visibleRect)
        guard !rect.isEmpty else { return }
        let popover = NSPopover(); popover.behavior = .transient; popover.animates = false
        popover.contentViewController = NSHostingController(rootView:
            Button { [weak self] in self?.dismissQuote(); self?.onQuote?(range) } label: {
                Label("添加到对话", systemImage: "text.bubble").padding(.horizontal, 8).padding(.vertical, 5)
            }.buttonStyle(.plain).padding(5))
        quotePopover = popover
        popover.show(relativeTo: NSRect(x: rect.midX, y: rect.minY, width: 1, height: 1), of: self, preferredEdge: .minY)
    }
}

struct DocumentSelectionText: NSViewRepresentable {
    let text: String
    let line: Int
    var onQuote: (NSRange) -> Void
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let view = QuoteSelectionTextView(); view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.drawsBackground = false; view.font = .systemFont(ofSize: 14); view.textColor = .labelColor
        view.textContainerInset = NSSize(width: 10, height: 10)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false; view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.setAccessibilityLabel("材料正文，选中文字可添加到对话")
        scroll.documentView = view
        return scroll
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? QuoteSelectionTextView else { return }
        view.onQuote = onQuote
        if view.string != text { view.dismissQuote(); view.string = text; context.coordinator.line = nil }
        if context.coordinator.line != line {
            context.coordinator.line = line
            let lines = text.components(separatedBy: "\n")
            let index = min(max(line - 1, 0), max(0, lines.count - 1))
            let start = (lines.prefix(index).joined(separator: "\n") as NSString).length + (index > 0 ? 1 : 0)
            let range = NSRange(location: start, length: (lines[index] as NSString).length)
            view.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: (text as NSString).length))
            if range.length > 0 { view.layoutManager?.addTemporaryAttribute(.backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.12), forCharacterRange: range) }
            DispatchQueue.main.async { [weak view] in view?.scrollRangeToVisible(range) }
        }
    }
    final class Coordinator { var line: Int? }
}
