import SwiftUI
import AudioCore

enum ReaderWorkspaceMode: String, CaseIterable {
    case reading, proofreading
    var title: String { self == .reading ? "阅读" : "校对" }
    var symbol: String { self == .reading ? "book" : "checkmark.bubble" }
    var contentWidth: CGFloat { self == .reading ? 760 : 900 }
}

struct ReadingLocation {
    let recordingID: String
    let runID: String?
    let segmentID: String?
    let position: Double
    let playing: Bool
    let filter: ReviewFilter
}

enum ReviewPresentation {
    static func title(for utterance: SpeechUtterance) -> String? {
        if utterance.reviewCount > 0 { return "待核对 \(utterance.reviewCount) 句" }
        if !utterance.segments.isEmpty && utterance.segments.allSatisfy({ $0.reviewed == true }) { return "已核对" }
        return nil
    }
}

extension AppModel {
    func setWorkspaceMode(_ mode: ReaderWorkspaceMode) {
        workspaceMode = mode
        reviewFilter = .all
        selectionMode = false
        bulkSelection = []
        savePreferences()
    }
    func dismissWelcome() {
        welcomeDismissed = true
        showWelcome = false
        savePreferences()
    }
    func rememberReadingPosition() {
        guard readingOrigin == nil, librarySection == .audio, let selectedID else { return }
        readingOrigin = ReadingLocation(recordingID: selectedID, runID: selected?.activeRun,
            segmentID: focusSegmentID, position: player.position, playing: player.playing, filter: reviewFilter)
    }
    func returnToReadingPosition() async {
        guard let origin = readingOrigin else { return }
        readingOrigin = nil
        librarySection = .audio
        await select(origin.recordingID)
        guard selectedID == origin.recordingID else { return }
        if let run = origin.runID, selected?.activeRun != run { await switchRun(run) }
        reviewFilter = origin.filter
        focusSegmentID = origin.segmentID ?? segments.first(where: { $0.start <= origin.position && origin.position < $0.end })?.id
        focusRequestID = UUID()
        player.seek(origin.position, play: origin.playing)
    }
    func revealSegment(_ id: String, play: Bool = false, revealAll: Bool = true) {
        guard let segment = segments.first(where: { $0.id == id }) else { return }
        rememberReadingPosition()
        if revealAll { reviewFilter = .all }
        focusSegmentID = id
        focusRequestID = UUID()
        if play { playSegment(segment) }
        else { player.seek(segment.start, play: false) }
    }
    func navigateReview(_ direction: Int) {
        let candidates = segments.filter(\.pendingReview)
        guard !candidates.isEmpty else { return }
        let anchor = focusSegmentID ?? currentSegmentID
        let next: TranscriptSegment?
        if let index = segments.firstIndex(where: { $0.id == anchor }) {
            let ordered = direction > 0 ? Array(segments.dropFirst(index + 1)) : Array(segments.prefix(index).reversed())
            next = ordered.first(where: \.pendingReview) ?? (direction > 0 ? candidates.first : candidates.last)
        } else { next = direction > 0 ? candidates.first : candidates.last }
        if let next { revealSegment(next.id, revealAll: false) }
    }
}

struct WelcomeChecklist: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("开始使用听阅", systemImage: "waveform.circle").font(.headline)
                Spacer()
                Button { model.dismissWelcome() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("关闭使用引导")
            }
            Text("准备本地模型后，导入一份音频开始阅读。助手可以稍后配置。")
                .font(.callout).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { steps }
                VStack(alignment: .leading, spacing: 12) { steps }
            }
            Text("点击句子回听 · 选中文字可提问或校对 · 切换到校对模式处理待核对内容")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).background(accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(ReaderTheme.border))
            .padding(20)
    }
    @ViewBuilder private var steps: some View {
        Button { model.showSettings = true } label: {
            Label(model.ready ? "本地模型已就绪" : "1 准备本地模型", systemImage: model.ready ? "checkmark.circle" : "cpu")
        }
        Button { model.pickFiles() } label: { Label("2 导入音频", systemImage: "plus") }
        Button { model.showAISettings = true } label: { Label("3 配置助手（可选）", systemImage: "sparkles") }
    }
}
