import Foundation

/// Display-only punctuation. Each decorated span still belongs to its original audio segment.
public struct ReadingTranscript: Sendable {
    public let text: String
    public let ranges: [String: NSRange]
    public let sentenceTexts: [String: String]
    private let canonical: JoinedTranscript
    private let segments: [TranscriptSegment]
    private let canonicalPositions: [Int: Int]

    public init(segments: [TranscriptSegment], punctuate: Bool = true, paragraphBreaks: Bool = true, density: ReadingDensity = .balanced, overrides: [String: String] = [:]) {
        self.segments = segments
        canonical = JoinedTranscript(segments: segments)
        var value = "", offsets: [String: NSRange] = [:], contents: [String: String] = [:]
        var sentenceLength = 0, paragraphLength = 0, sourcePositions: [Int: Int] = [:]
        for (index, segment) in segments.enumerated() {
            let next = index + 1 < segments.count ? segments[index + 1] : nil
            let smart = punctuate ? overrides[segment.id] : nil
            let original = smart ?? (punctuate ? ReadingPunctuation.listContent(segment.text, after: index > 0 ? segments[index - 1].text : nil) : segment.text)
            sentenceLength += original.count; paragraphLength += original.count
            let mark = punctuate && smart == nil ? ReadingPunctuation.ending(for: segment, next: next, sentenceLength: sentenceLength) : ""
            let decorated = original + mark
            let start = (value as NSString).length
            value += decorated
            offsets[segment.id] = NSRange(location: start, length: (decorated as NSString).length)
            contents[segment.id] = decorated
            if let rawRange = canonical.ranges[segment.id] {
                for (index, position) in (smart != nil ? PunctuationProjection.positions(source: segment.text, display: decorated) : Array(0..<rawRange.length)).enumerated() {
                    sourcePositions[rawRange.location + index] = start + position
                }
            }
            let stop = ReadingPunctuation.endsSentence(decorated)
            if stop { sentenceLength = 0 }
            if let next {
                let newTopic = ReadingPunctuation.startsTopic(next.text)
                if paragraphBreaks, stop, paragraphLength >= density.paragraphLimit || (newTopic && paragraphLength >= density.paragraphLimit * 3 / 5) {
                    if !value.hasSuffix("\n") { value += "\n" }
                    paragraphLength = 0
                } else if let last = value.last, let first = next.text.first,
                          last.isReadingWordCharacter, first.isReadingWordCharacter { value += " " }
            }
        }
        text = value; ranges = offsets; sentenceTexts = contents; canonicalPositions = sourcePositions
    }

    public func searchRanges(for term: String) -> [NSRange] {
        guard !term.isEmpty else { return [] }
        var result = Self.find(term, in: text)
        for match in Self.find(term, in: canonical.text) {
            guard let start = canonicalPositions[match.location], let last = canonicalPositions[NSMaxRange(match) - 1] else { continue }
            let translated = NSRange(location: start, length: max(0, last + 1 - start))
            if translated.length > 0, !result.contains(translated) { result.append(translated) }
        }
        return result.sorted { $0.location < $1.location }
    }
    private static func find(_ term: String, in value: String) -> [NSRange] {
        let source = value as NSString
        var remaining = NSRange(location: 0, length: source.length), result: [NSRange] = []
        while remaining.length > 0 {
            let match = source.range(of: term, options: .caseInsensitive, range: remaining)
            if match.location == NSNotFound { break }
            result.append(match)
            remaining = NSRange(location: NSMaxRange(match), length: source.length - NSMaxRange(match))
        }
        return result
    }
}

private extension Character {
    var isReadingWordCharacter: Bool { unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) } }
}

private enum ReadingPunctuation {
    static let terminal = CharacterSet(charactersIn: "。！？!?；;，,：:、….")
    static let closing = CharacterSet(charactersIn: "\"'”’」』）)]}")
    static let incomplete = ["的","和","与","及","或","在","把","让","将","能","可以","会","对","从","由","到","向","以","为","给","要","想","需要","是","通过","对于","为了","因为","所以","比如","包括","主要是","就是","采用","使用","负责","进行","实现","处理","完成","增加","介绍","提供","讨论","分析","说明","安排","维护","构建","优化","支持","保证","提高","减少"]
    static let compounds = ["数据库事务","代码自动","代码生成","自动验证","自动修复","客户端代码","服务端代码","知识库检索","语音识别","机器学习","深度学习","并发安全","线程安全","人工智能","工作流程"]
    static func effectiveEnd(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: closing)
    }
    static func containsChinese(_ text: String) -> Bool { text.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) } }
    static func endsSentence(_ text: String) -> Bool {
        guard let last = effectiveEnd(text).last else { return false }
        return "。！？!?.".contains(last)
    }
    static func startsTopic(_ text: String) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["同时","另外","后面","接下来","除此之外","最后","关于","另一方面"].contains { clean.hasPrefix($0) }
    }
    static func isQuestion(_ text: String) -> Bool {
        if ["吗","是不是","对不对"].contains(where: { text.hasSuffix($0) }) { return true }
        if text.hasSuffix("呢") && ["你","如何","怎么","为什么","多少","哪些","什么"].contains(where: { text.contains($0) }) { return true }
        let opening = ["请问","你","您","为什么","怎么","如何","有没有","能不能","是否","那","到"]
        let question = ["哪里","哪儿","哪种","哪些","哪个","什么","怎么","如何","为什么","多少","多长","多久","几点"]
        let instruction = ["你可以","你需要","你应该","你先","你要","你刚才","你说"]
        return opening.contains(where: { text.hasPrefix($0) }) && question.contains(where: { text.contains($0) }) && !instruction.contains(where: { text.hasPrefix($0) })
    }
    static func listContent(_ text: String, after previous: String?) -> String {
        guard let previous, ["三件事","几个方面","以下几点","如下"].contains(where: { effectiveEnd(previous).hasSuffix($0) }) else { return text }
        let items = text.components(separatedBy: " ")
        guard (2...6).contains(items.count), items.allSatisfy({ (2...12).contains($0.count) && $0.unicodeScalars.allSatisfy { (0x3400...0x9fff).contains($0.value) } }) else { return text }
        // A single ASCII space and a Chinese list separator both occupy one UTF-16 unit.
        return items.joined(separator: "、")
    }
    static func ending(for segment: TranscriptSegment, next: TranscriptSegment?, sentenceLength: Int) -> String {
        let left = effectiveEnd(segment.text)
        guard let last = left.unicodeScalars.last, !terminal.contains(last), !left.isEmpty else { return "" }
        guard containsChinese(left) else { return "" }
        guard let next else { return isQuestion(left) ? "？" : "。" }
        let right = next.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if right.isEmpty { return "" }
        if right.unicodeScalars.first.map({ terminal.contains($0) }) == true { return "" }
        if isQuestion(left) { return "？" }
        if sentenceLength >= 10, startsTopic(right), ["的","了","着"].contains(where: { left.hasSuffix($0) }) { return "。" }
        if left.contains("从"), ["挪到","转到","迁移到"].contains(where: { right.hasPrefix($0) }) { return "" }
        if ["上","中","里","下"].contains(where: { left.hasSuffix($0) }), ["搭建","打建","构建","建立","完成","实现"].contains(where: { right.hasPrefix($0) }) { return "" }
        let startsParticle = ["的","了","着","过"].contains(where: { right.hasPrefix($0) }) && !["的确","了解","了结","了不起","着重","过去","过后"].contains(where: { right.hasPrefix($0) })
        if (left != "对" && incomplete.contains(where: { left.hasSuffix($0) })) || startsParticle { return "" }
        if compounds.contains(where: { compound in
            (1..<compound.count).contains { split in left.hasSuffix(String(compound.prefix(split))) && right.hasPrefix(String(compound.dropFirst(split))) }
        }) { return "" }
        if ["三件事","几个方面","以下几点","如下"].contains(where: { left.hasSuffix($0) }) { return "：" }
        let pause = max(0, next.start - segment.end)
        if pause >= 0.9 || sentenceLength >= 52 || (sentenceLength >= 28 && startsTopic(right)) { return "。" }
        return "，"
    }
}
