import SwiftUI
import AppKit
import AudioCore

/// A flowing native paragraph with one real audio link per original timed sentence.
struct ParagraphTextView: NSViewRepresentable {
    let segments: [TranscriptSegment]
    let fontSize: Double
    let activeID: String?
    let focusedID: String?
    let focusRequest: UUID
    let searchTerm: String
    let followPlayback: Bool
    let playing: Bool
    let punctuate: Bool
    let paragraphBreaks: Bool
    var onPlay: (String) -> Void
    var onEdit: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSTextView {
        let view = ParagraphNativeTextView(frame: .zero)
        view.isEditable = false; view.isSelectable = true; view.isRichText = true
        view.drawsBackground = false; view.isHorizontallyResizable = false; view.isVerticallyResizable = true
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.heightTracksTextView = false
        view.linkTextAttributes = [.foregroundColor: NSColor.labelColor, .underlineStyle: 0]
        view.delegate = context.coordinator; view.coordinator = context.coordinator
        view.setAccessibilityHelp("点击句子回听；右键可校对或复制。")
        context.coordinator.view = view
        return view
    }
    func updateNSView(_ view: NSTextView, context: Context) {
        let coordinator = context.coordinator
        let joined = ReadingTranscript(segments: segments, punctuate: punctuate, paragraphBreaks: paragraphBreaks)
        let active = activeID.flatMap { joined.ranges[$0] == nil ? nil : $0 }
        let focused = focusedID.flatMap { joined.ranges[$0] == nil ? nil : $0 }
        let key = RenderKey(segments: segments, fontSize: fontSize, active: active, focused: focused, search: searchTerm,
                            punctuate: punctuate, paragraphBreaks: paragraphBreaks)
        let activeChanged = coordinator.renderKey?.active != active
        coordinator.onPlay = onPlay; coordinator.onEdit = onEdit
        coordinator.segments = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
        if coordinator.renderKey != key {
            (view as? ParagraphNativeTextView)?.clearHover()
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 7; paragraph.lineBreakMode = .byWordWrapping; paragraph.paragraphSpacing = fontSize * 0.55
            let value = NSMutableAttributedString(string: joined.text, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
            ])
            for segment in segments {
                guard let range = joined.ranges[segment.id], range.length > 0 else { continue }
                value.addAttribute(.link, value: segment.id, range: range)
                if !punctuate, segment.id != segments.last?.id, let last = segment.text.last, !last.isWhitespace,
                   !"。！？!?；;，,.".contains(last) {
                    // Visual breathing room between clickable phrases, without inserting characters or changing search ranges.
                    let tail = (joined.text as NSString).rangeOfComposedCharacterSequence(at: NSMaxRange(range) - 1)
                    value.addAttribute(.kern, value: fontSize * 0.22, range: tail)
                }
                if segment.id == active {
                    value.addAttributes([.backgroundColor: ReaderTheme.tint.withAlphaComponent(0.16), .foregroundColor: ReaderTheme.tint], range: range)
                }
                if segment.id == focused { value.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: ReaderTheme.tint], range: range) }
            }
            if !searchTerm.isEmpty {
                for match in joined.searchRanges(for: searchTerm) {
                    value.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.25), range: match)
                }
            }
            let selection = view.selectedRanges
            let unchangedText = view.string == joined.text
            view.textStorage?.setAttributedString(value)
            if unchangedText { view.selectedRanges = selection }
            view.invalidateIntrinsicContentSize()
            coordinator.renderKey = key
        }
        coordinator.ranges = joined.ranges
        coordinator.sentenceTexts = joined.sentenceTexts
        let explicitFocus = coordinator.lastFocusRequest != focusRequest && focused != nil
        coordinator.lastFocusRequest = focusRequest
        let reveal = explicitFocus ? focused : (followPlayback && playing && activeChanged ? active : nil)
        if let id = reveal, let range = joined.ranges[id] {
            DispatchQueue.main.async { [weak view] in
                guard let view, let container = view.textContainer, let layout = view.layoutManager else { return }
                layout.ensureLayout(for: container)
                let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
                if explicitFocus || !view.visibleRect.insetBy(dx: 0, dy: 12).contains(rect) {
                    _ = view.scrollToVisible(rect.insetBy(dx: 0, dy: -20))
                }
            }
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, let container = nsView.textContainer, let layout = nsView.layoutManager else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: max(26, ceil(layout.usedRect(for: container).height) + 3))
    }
    struct RenderKey: Equatable {
        var segments: [TranscriptSegment]; var fontSize: Double; var active: String?; var focused: String?; var search: String
        var punctuate: Bool; var paragraphBreaks: Bool
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var view: NSTextView?
        var renderKey: RenderKey?
        var ranges: [String: NSRange] = [:]
        var segments: [String: TranscriptSegment] = [:]
        var sentenceTexts: [String: String] = [:]
        var lastFocusRequest: UUID?
        var onPlay: ((String) -> Void)?
        var onEdit: ((String) -> Void)?
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let id = (link as? String) ?? (link as? URL)?.absoluteString, segments[id] != nil { onPlay?(id) }
            return true // Never forward internal audio links to a browser.
        }
        @objc func play(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { onPlay?(id) } }
        @objc func edit(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { onEdit?(id) } }
        @objc func copySentence(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? String, let segment = segments[id] else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(sentenceTexts[id] ?? segment.text, forType: .string)
        }
    }
}

private final class ParagraphNativeTextView: NSTextView {
    weak var coordinator: ParagraphTextView.Coordinator?
    private var tracking: NSTrackingArea?
    private var hovered: String?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited], owner: self, userInfo: nil)
        addTrackingArea(area); tracking = area
    }
    private func sentence(at event: NSEvent) -> String? {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let glyph = layout.glyphIndex(for: point, in: container)
        guard glyph < layout.numberOfGlyphs else { return nil }
        let bounds = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard bounds.insetBy(dx: -2, dy: -2).contains(point) else { return nil }
        let character = layout.characterIndexForGlyph(at: glyph)
        return storage.attribute(.link, at: character, effectiveRange: nil) as? String
    }
    override func mouseMoved(with event: NSEvent) {
        let id = sentence(at: event)
        guard id != hovered else { return }
        clearHover(); hovered = id
        if let id, let range = coordinator?.ranges[id] {
            layoutManager?.addTemporaryAttribute(.backgroundColor, value: ReaderTheme.tint.withAlphaComponent(0.08), forCharacterRange: range)
            if let sentence = coordinator?.segments[id] { toolTip = "回听 \(TimeFormat.clock(sentence.start)) – \(TimeFormat.clock(sentence.end)) · 右键校对" }
        }
    }
    override func mouseExited(with event: NSEvent) { clearHover() }
    fileprivate func clearHover() {
        if let hovered, let range = coordinator?.ranges[hovered] { layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range) }
        hovered = nil
        toolTip = nil
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let id = sentence(at: event), let coordinator else { return super.menu(for: event) }
        let menu = NSMenu()
        for (title, action) in [("回听这句话", #selector(ParagraphTextView.Coordinator.play(_:))),
                                ("校对这句话…", #selector(ParagraphTextView.Coordinator.edit(_:))),
                                ("复制这句话", #selector(ParagraphTextView.Coordinator.copySentence(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = coordinator; item.representedObject = id; menu.addItem(item)
        }
        if selectedRange().length > 0 {
            menu.addItem(.separator())
            let copy = NSMenuItem(title: "复制所选文字", action: #selector(NSText.copy(_:)), keyEquivalent: "")
            copy.target = self; menu.addItem(copy)
        }
        return menu
    }
}
