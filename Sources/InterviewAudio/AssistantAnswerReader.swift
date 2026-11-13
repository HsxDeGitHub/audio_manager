import SwiftUI
import AppKit

private struct AssistantFontSizeKey: EnvironmentKey { static let defaultValue: CGFloat = 14 }
extension EnvironmentValues {
    var assistantFontSize: CGFloat {
        get { self[AssistantFontSizeKey.self] }
        set { self[AssistantFontSizeKey.self] = newValue }
    }
}

enum AssistantTextSearch {
    static func ranges(in text: String, query: String) -> [NSRange] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        let value = text as NSString
        var result: [NSRange] = []
        var start = 0
        while start < value.length {
            let range = value.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: start, length: value.length - start))
            if range.location == NSNotFound { break }
            result.append(range)
            start = NSMaxRange(range)
        }
        return result
    }
    static func highlight(_ text: AttributedString, query: String, selected: NSRange?) -> AttributedString {
        var result = text
        let plain = String(text.characters)
        for range in ranges(in: plain, query: query) {
            guard let stringRange = Range(range, in: plain) else { continue }
            let start = result.characters.index(result.startIndex, offsetBy: plain.distance(from: plain.startIndex, to: stringRange.lowerBound))
            let end = result.characters.index(result.startIndex, offsetBy: plain.distance(from: plain.startIndex, to: stringRange.upperBound))
            result[start..<end].backgroundColor = range == selected ? accent.opacity(0.38) : Color.yellow.opacity(0.25)
        }
        return result
    }
}

struct AssistantMarkdownDocument {
    struct Line: Identifiable {
        let id: Int
        let text: AttributedString
        let heading: Int
    }
    struct Block: Identifiable {
        let id: Int
        let code: Bool
        let lines: [Line]
    }
    struct Match: Identifiable {
        let id: Int
        let lineID: Int
        let range: NSRange
    }
    let blocks: [Block]

    init(_ text: String) {
        var result: [Block] = []
        var pending: [(Int, String)] = []
        var code = false
        func flush() {
            guard let first = pending.first else { return }
            let lines: [Line]
            if code {
                lines = [Line(id: first.0, text: AttributedString(pending.map(\.1).joined(separator: "\n")), heading: 0)]
            } else {
                lines = pending.map { index, raw in
                    let prefix = raw.prefix(while: { $0 == "#" }).count
                    let heading = prefix > 0 && raw.dropFirst(prefix).hasPrefix(" ") ? prefix : 0
                    let content = heading > 0 ? String(raw.dropFirst(heading + 1)) : raw
                    let markdown = content.replacingOccurrences(of: "^- ", with: "• ", options: .regularExpression)
                    let value = (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(content)
                    return Line(id: index, text: value, heading: heading)
                }
            }
            result.append(Block(id: first.0, code: code, lines: lines))
            pending = []
        }
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            if line.hasPrefix("```") { flush(); code.toggle() }
            else if !code && line.isEmpty { flush() }
            else { pending.append((index, line)) }
        }
        flush()
        blocks = result
    }
    func matches(_ query: String) -> [Match] {
        var result: [Match] = []
        for line in blocks.flatMap(\.lines) {
            for range in AssistantTextSearch.ranges(in: String(line.text.characters), query: query) {
                result.append(Match(id: result.count, lineID: line.id, range: range))
            }
        }
        return result
    }
}

struct AssistantMarkdown: View {
    let text: String
    var query = ""
    var selectedMatch: AssistantMarkdownDocument.Match? = nil
    var scrollTargets = false
    @Environment(\.assistantFontSize) private var fontSize
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(AssistantMarkdownDocument(text).blocks) { block in
                if block.code, let line = block.lines.first {
                    ScrollView(.horizontal) {
                        anchored(Text(highlight(line)).font(.system(size: max(12, fontSize - 1), design: .monospaced))
                            .textSelection(.enabled).padding(10), lineID: line.id)
                    }.background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(block.lines) { line in
                            anchored(Text(highlight(line)).font(.system(size: line.heading > 0 ? fontSize + 2 : fontSize, weight: line.heading > 0 ? .semibold : .regular))
                                .lineSpacing(4).textSelection(.enabled).fixedSize(horizontal: false, vertical: true), lineID: line.id)
                        }
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func highlight(_ line: AssistantMarkdownDocument.Line) -> AttributedString {
        AssistantTextSearch.highlight(line.text, query: query, selected: selectedMatch?.lineID == line.id ? selectedMatch?.range : nil)
    }
    @ViewBuilder private func anchored<Content: View>(_ content: Content, lineID: Int) -> some View {
        if scrollTargets { content.id(lineID) } else { content }
    }
}

struct AssistantAnswerReader: View {
    let text: String
    var title = "本次回答"
    private let document: AssistantMarkdownDocument
    @Environment(\.dismiss) private var dismiss
    @AppStorage("assistant.fontSize") private var storedFontSize = 14.0
    @UIState private var query = ""
    @UIState private var matchIndex = 0
    @FocusState private var searchFocused: Bool
    init(text: String, title: String = "本次回答") {
        self.text = text; self.title = title; document = AssistantMarkdownDocument(text)
    }
    private var matches: [AssistantMarkdownDocument.Match] { document.matches(query) }
    private var currentMatch: AssistantMarkdownDocument.Match? { matches.isEmpty ? nil : matches[min(matchIndex, matches.count - 1)] }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 14) {
                HStack {
                    Text(title).font(.title2.weight(.semibold))
                    Spacer()
                    Stepper("字号 \(Int(storedFontSize))", value: $storedFontSize, in: 12...22, step: 1)
                        .fixedSize().accessibilityLabel("回答字号")
                    Button("复制回答") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
                    Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                HStack {
                    TextField("在本次回答中查找…", text: $query).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("在本次回答中查找").focused($searchFocused).onSubmit { move(1) }
                    if !query.isEmpty {
                        Text(matches.isEmpty ? "未找到" : "\(min(matchIndex + 1, matches.count))/\(matches.count)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Button { move(-1) } label: { Image(systemName: "chevron.up") }.disabled(matches.isEmpty).accessibilityLabel("上一个匹配")
                    Button { move(1) } label: { Image(systemName: "chevron.down") }.disabled(matches.isEmpty).accessibilityLabel("下一个匹配")
                    Button("查找") { searchFocused = true }.keyboardShortcut("f", modifiers: .command)
                }
                Divider()
                ScrollView {
                    HStack {
                        Spacer(minLength: 0)
                        AssistantMarkdown(text: text, query: query, selectedMatch: currentMatch, scrollTargets: true).frame(maxWidth: 680, alignment: .leading)
                        Spacer(minLength: 0)
                    }.padding(20)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.padding(22).frame(minWidth: 760, idealWidth: 900, minHeight: 540, idealHeight: 680)
                .environment(\.assistantFontSize, CGFloat(min(22, max(12, storedFontSize))))
                .task { searchFocused = true }
                .onChange(of: query) { _, _ in
                    matchIndex = 0
                    if let match = currentMatch { proxy.scrollTo(match.lineID, anchor: .center) }
                }
                .onChange(of: matchIndex) { _, _ in
                    if let match = currentMatch { proxy.scrollTo(match.lineID, anchor: .center) }
                }
        }
    }
    private func move(_ step: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + step + matches.count) % matches.count
    }
}
