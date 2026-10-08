import Foundation
import AVFoundation
import AudioCore

@MainActor
final class PlayerController: ObservableObject {
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var playing = false
    @Published var speed: Float = 1
    @Published var available = false
    @Published var error: String?
    @Published var loop: PlaybackLoop?
    private var playbackBoundary: PlaybackLoop?
    private var loopingSeek = false
    private var player: AVPlayer?
    private var observer: Any?
    private var endObserver: NSObjectProtocol?
    private var generation = UUID()
    var onPosition: ((Double) -> Void)?
    func unload() {
        stopLoop(); generation = UUID()
        if let observer { player?.removeTimeObserver(observer) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        player?.pause(); player = nil; observer = nil; endObserver = nil
        playing = false; available = false; position = 0; duration = 0; error = nil
    }
    func load(url: URL, fingerprint: String, position: Double) async {
        unload(); let token = generation
        do {
            try await Task.detached(priority: .utility) { try FileFingerprint.verify(url, expected: fingerprint) }.value
            let asset = AVURLAsset(url: url)
            let length = try await asset.load(.duration).seconds
            guard token == generation else { return }
            guard length.isFinite, length > 0 else { throw AudioError.message("无法读取音频时长") }
            let player = AVPlayer(playerItem: AVPlayerItem(asset: asset)); self.player = player
            duration = length; available = true
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] value in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    let seconds = max(0, value.seconds.isFinite ? value.seconds : 0)
                    if let boundary = self.playbackBoundary, seconds >= boundary.end - 0.02, self.player?.rate != 0, !self.loopingSeek {
                        if self.loop != nil {
                            self.loopingSeek = true
                            self.player?.seek(to: CMTime(seconds: boundary.start, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                                Task { @MainActor in guard let self, self.generation == token else { return }; self.loopingSeek = false }
                            }
                            return
                        } else { self.pause(); self.playbackBoundary = nil }
                    }
                    self.position = seconds
                    self.playing = self.player?.rate != 0
                    self.onPosition?(self.position)
                }
            }
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    if let loop = self.loop { self.seek(loop.start, play: true, preserveLoop: true) } else { self.playing = false }
                }
            }
            seek(min(position, max(0, length - 0.1)), play: false)
        } catch { if token == generation { self.error = "原音频不可用：\(error.localizedDescription)" } }
    }
    func toggle() {
        guard let player, available else { return }
        if playing { player.pause(); playing = false }
        else { if position >= duration - 0.1 { seek(0, play: false) }; player.playImmediately(atRate: speed); playing = true }
    }
    func pause() { player?.pause(); playing = false }
    func stopLoop() { loop = nil; playbackBoundary = nil; loopingSeek = false }
    func startLoop(start: Double, end: Double) {
        guard available, let range = PlaybackLoop(start: start, end: end, duration: duration) else { return }
        loop = range; playbackBoundary = range; seek(range.start, play: true, preserveLoop: true)
    }
    func playExcerpt(start: Double, end: Double) {
        stopLoop()
        guard available, let range = PlaybackLoop(start: start, end: end, duration: duration) else { return }
        playbackBoundary = range; seek(range.start, play: true, preserveLoop: true)
    }
    func seek(_ seconds: Double, play: Bool? = nil, preserveLoop: Bool = false) {
        guard available, let player else { return }
        if !preserveLoop { stopLoop() }
        let target = min(duration, max(0, seconds))
        position = target
        let shouldPlay = play ?? playing
        player.seek(to: CMTime(seconds: target, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
        if shouldPlay { player.playImmediately(atRate: speed); playing = true }
        else { player.pause(); playing = false }
        onPosition?(target)
    }
    func setSpeed(_ value: Float) { speed = value; if playing { player?.rate = value } }
}
