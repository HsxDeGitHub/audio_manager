import SwiftUI
import AppKit

enum AssistantInputPolicy {
    static func shouldSend(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, marked: Bool) -> Bool {
        [36, 76].contains(keyCode) && !marked && modifiers.intersection([.shift, .option, .control]).isEmpty
    }
}

struct AssistantInput: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var focusRequest: UUID
    var onSend: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.borderType = .noBorder
        let editor = ComposerTextView()
        editor.isRichText = false; editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = true; editor.allowsUndo = true
        editor.font = .systemFont(ofSize: 14); editor.textColor = .labelColor; editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 5, height: 7)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = context.coordinator
        editor.setAccessibilityLabel("向听阅助手提问")
        editor.onSend = { context.coordinator.parent.onSend() }
        editor.string = text; scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? ComposerTextView else { return }
        if editor.string != text && !editor.hasMarkedText() { editor.string = text; editor.undoManager?.removeAllActions() }
        context.coordinator.measure(editor)
        if context.coordinator.focus != focusRequest {
            context.coordinator.focus = focusRequest
            DispatchQueue.main.async { [weak editor] in if let editor, editor.window != nil { editor.window?.makeFirstResponder(editor) } }
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AssistantInput; var focus: UUID?
        init(_ parent: AssistantInput) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string; measure(editor)
        }
        func measure(_ editor: NSTextView) {
            guard let container = editor.textContainer, let layout = editor.layoutManager else { return }
            layout.ensureLayout(for: container)
            let value = min(170, max(54, ceil(layout.usedRect(for: container).height + 16)))
            if abs(value - parent.height) > 1 { DispatchQueue.main.async { [weak self] in self?.parent.height = value } }
        }
    }
}

final class ComposerTextView: NSTextView {
    var onSend: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if AssistantInputPolicy.shouldSend(keyCode: event.keyCode, modifiers: event.modifierFlags, marked: hasMarkedText()) { onSend?() }
        else { super.keyDown(with: event) }
    }
}

struct AssistantMarkdown: View {
    let text: String
    private var blocks: [Block] {
        var result: [Block] = []; var lines: [String] = []; var code = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if !lines.isEmpty { result.append(Block(text: lines.joined(separator: "\n"), code: code)); lines = [] }
                code.toggle()
            } else if !code && line.isEmpty {
                if !lines.isEmpty { result.append(Block(text: lines.joined(separator: "\n"), code: false)); lines = [] }
            } else { lines.append(line) }
        }
        if !lines.isEmpty { result.append(Block(text: lines.joined(separator: "\n"), code: code)) }
        return result
    }
    private struct Block { let text: String; let code: Bool }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                if block.code {
                    ScrollView(.horizontal) { Text(block.text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).padding(10) }
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                } else {
                    ForEach(Array(block.text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                        let heading = line.prefix(while: { $0 == "#" }).count
                        let content = heading > 0 && line.dropFirst(heading).hasPrefix(" ") ? String(line.dropFirst(heading + 1)) : line
                        Text((try? AttributedString(markdown: content.replacingOccurrences(of: "^- ", with: "• ", options: .regularExpression), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(content))
                            .font(heading > 0 ? .headline : .system(size: 14)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 只依据用户滚动调整跟随意图；程序滚动或正文增高不会误关跟随。
struct AssistantScrollProbe: NSViewRepresentable {
    var onScroll: (Bool) -> Void
    func makeNSView(context: Context) -> Probe { let view = Probe(); view.onScroll = onScroll; return view }
    func updateNSView(_ view: Probe, context: Context) { view.onScroll = onScroll }
    final class Probe: NSView {
        var onScroll: ((Bool) -> Void)?
        private var tokens: [NSObjectProtocol] = []
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach(NotificationCenter.default.removeObserver); tokens = []
            DispatchQueue.main.async { [weak self] in
                guard let self, let scroll = self.enclosingScrollView else { return }
                for name in [NSScrollView.didLiveScrollNotification, NSScrollView.didEndLiveScrollNotification] {
                    self.tokens.append(NotificationCenter.default.addObserver(forName: name, object: scroll, queue: .main) { [weak self, weak scroll] _ in
                        guard let scroll, let document = scroll.documentView else { return }
                        self?.onScroll?(document.bounds.height - scroll.contentView.bounds.maxY < 48)
                    })
                }
            }
        }
        deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    }
}
