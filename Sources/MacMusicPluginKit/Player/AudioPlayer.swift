import AVFoundation
import Foundation

/// Thin wrapper over `AVAudioEngine` + `AVAudioPlayerNode` for gapless local
/// playback with seeking, software gain, and output-device selection.
///
/// Replaces the SDL queue plumbing in the C backend (`stream_audio`, `seek_ms`,
/// `reapply_output_gain`, `retry_audio_device`). AVFoundation owns decoding and
/// buffering, so most of that complexity is gone; what remains is position
/// tracking and rebuilding the graph when the audio device changes.
@MainActor
final class AudioPlayer {
    /// Called on the main actor when the currently scheduled audio finishes on
    /// its own (not via `stop()` or `seek`).
    var onTrackEnded: (() -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    private var file: AVAudioFile?
    private var sampleRate: Double = 44_100
    private var totalFrames: AVAudioFramePosition = 0

    /// Frame the current schedule started from; added to the node's own clock to
    /// get an absolute position after a seek.
    private var scheduleStartFrame: AVAudioFramePosition = 0
    /// Bumped on every (re)schedule so stale completion callbacks are ignored.
    private var generation = 0

    private var volume = 100
    private var muted = false
    private(set) var outputDeviceName: String?

    private(set) var isPlaying = false

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(configurationChanged),
            name: .AVAudioEngineConfigurationChange, object: engine)
    }

    var durationMs: Int { frameToMs(totalFrames) }

    var positionMs: Int {
        guard let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else {
            return frameToMs(scheduleStartFrame)
        }
        let absolute = scheduleStartFrame + playerTime.sampleTime
        return frameToMs(max(0, min(absolute, totalFrames)))
    }

    // MARK: Loading

    /// Opens `url`, rebuilds the graph for its format, and starts playing from
    /// the top. Throws if the file cannot be opened or the engine cannot start.
    func load(url: URL, playing: Bool) throws {
        let audioFile = try AVAudioFile(forReading: url)
        stopInternal()

        file = audioFile
        sampleRate = audioFile.processingFormat.sampleRate
        totalFrames = audioFile.length

        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: audioFile.processingFormat)
        applyGain()

        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }

        schedule(fromFrame: 0)
        isPlaying = playing
        if playing { player.play() }
    }

    // MARK: Transport

    func play() {
        guard file != nil else { return }
        if !engine.isRunning { try? engine.start() }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func stop() {
        stopInternal()
        file = nil
        totalFrames = 0
        scheduleStartFrame = 0
    }

    func seek(toMs ms: Int) {
        guard file != nil, sampleRate > 0 else { return }
        let target = max(0, min(msToFrame(ms), totalFrames))
        let wasPlaying = isPlaying
        haltPlayback()
        schedule(fromFrame: target)
        if wasPlaying { player.play() }
    }

    // MARK: Output shaping

    func setGain(volume: Int, muted: Bool) {
        self.volume = max(0, min(100, volume))
        self.muted = muted
        applyGain()
    }

    /// Repoints the engine at another device, resuming from the same position.
    /// `nil` selects the system default. Returns the name actually selected.
    @discardableResult
    func setOutputDevice(name: String?) -> String? {
        let resumeAt = positionMs
        let wasPlaying = isPlaying

        haltPlayback()
        engine.stop()
        let applied = AudioOutput.select(name, on: engine)
        outputDeviceName = applied

        guard file != nil else { return applied }
        do {
            engine.prepare()
            try engine.start()
            schedule(fromFrame: max(0, min(msToFrame(resumeAt), totalFrames)))
            if wasPlaying { player.play() }
        } catch {
            isPlaying = false
        }
        return applied
    }

    // MARK: Internals

    private func schedule(fromFrame startFrame: AVAudioFramePosition) {
        guard let file else { return }
        scheduleStartFrame = startFrame
        generation += 1
        let thisGeneration = generation
        let remaining = AVAudioFrameCount(max(0, totalFrames - startFrame))
        guard remaining > 0 else {
            deliverTrackEnded(generation: thisGeneration)
            return
        }
        player.scheduleSegment(file, startingFrame: startFrame, frameCount: remaining,
                               at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.deliverTrackEnded(generation: thisGeneration) }
        }
    }

    private func deliverTrackEnded(generation: Int) {
        guard generation == self.generation, isPlaying else { return }
        isPlaying = false
        onTrackEnded?()
    }

    /// Stops the player node and invalidates any pending completion callback, so
    /// a `stop()` mid-track is never mistaken for the track ending.
    private func haltPlayback() {
        generation += 1
        player.stop()
    }

    private func applyGain() {
        player.volume = Float(muted ? 0 : volume) / 100
    }

    private func stopInternal() {
        haltPlayback()
        isPlaying = false
    }

    @objc private func configurationChanged() {
        // The output device changed under us. Rebuild and resume from position.
        Task { @MainActor in
            guard self.file != nil else { return }
            let resumeAt = self.positionMs
            let wasPlaying = self.isPlaying
            if !self.engine.isRunning { try? self.engine.start() }
            self.haltPlayback()
            self.schedule(fromFrame: max(0, min(self.msToFrame(resumeAt), self.totalFrames)))
            if wasPlaying { self.player.play() }
        }
    }

    private func frameToMs(_ frame: AVAudioFramePosition) -> Int {
        sampleRate > 0 ? Int(Double(frame) / sampleRate * 1000) : 0
    }

    private func msToFrame(_ ms: Int) -> AVAudioFramePosition {
        AVAudioFramePosition(Double(ms) / 1000 * sampleRate)
    }
}
