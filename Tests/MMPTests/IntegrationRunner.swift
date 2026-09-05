import Foundation
@testable import MacMusicPluginKit

/// Exercises the real `PlayerEngine` + `AudioPlayer` against on-disk audio files.
/// Not part of the CI suite (GitHub runners have no audio device); run locally:
///
///     swift run MMPTests --audio /path/to/folder-with-3-audio-files
enum IntegrationRunner {
    @MainActor
    static func run(audioDir: String) async -> Int {
        var failures = 0
        func check(_ cond: Bool, _ msg: String) {
            print(cond ? "  ok   \(msg)" : "  FAIL \(msg)")
            if !cond { failures += 1 }
        }

        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(atPath: audioDir)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
            .map { "\(audioDir)/\($0)" }
        guard files.count >= 2 else {
            print("need at least 2 audio files in \(audioDir)"); return 1
        }

        let root = fm.temporaryDirectory.appendingPathComponent("mmp-integration-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let library = LibraryStore(directory: root.appendingPathComponent("library"))
        try? library.bootstrap()

        let defaults = UserDefaults(suiteName: "mmp-integration-\(UUID().uuidString)")!
        let engine = PlayerEngine(library: library, defaults: defaults)
        engine.start()

        for (i, path) in files.enumerated() {
            try? engine.addLocalFile(path: path,
                                     metadata: TrackMetadata(title: "Track \(i + 1)", artist: "T", album: "Rec"))
        }
        check(engine.viewedTracks.count == files.count, "added \(files.count) tracks to home")

        // Play the first track.
        engine.playFromViewed(0)
        await settle(1.5)
        check(engine.isPlaying, "playing after playFromViewed(0)")
        check(engine.durationMs > 3000, "duration read (\(engine.durationMs)ms)")
        check(engine.selectedIndex == 0, "selectedIndex == 0")
        let p1 = engine.positionMs
        await settle(1.5)
        check(engine.positionMs > p1 + 500, "position advancing (\(p1) -> \(engine.positionMs))")

        // Pause / resume.
        engine.togglePlayPause()
        await settle(0.8)
        check(!engine.isPlaying, "paused")
        let pausedAt = engine.positionMs
        await settle(1)
        check(abs(engine.positionMs - pausedAt) < 200, "position held while paused (\(pausedAt) -> \(engine.positionMs))")
        engine.togglePlayPause()
        await settle(0.8)
        check(engine.isPlaying, "resumed")

        // Seek forward, confirm the clock jumps.
        engine.seek(toMs: engine.durationMs - 2500)
        await settle(0.6)
        check(engine.positionMs > engine.durationMs - 3500 && engine.positionMs < engine.durationMs,
              "seek landed near the end (\(engine.positionMs) of \(engine.durationMs))")

        // Let the track finish -> autoplay advance to track 2.
        await settle(4)
        check(engine.selectedIndex == 1, "autoplay advanced to track 2 (got \(engine.selectedIndex))")
        check(engine.isPlaying, "still playing after advance")

        // Manual next -> track 3.
        engine.next()
        await settle(1.5)
        check(engine.selectedIndex == 2, "next() moved to track 3 (got \(engine.selectedIndex))")

        // Resume round-trip: shut down, rebuild, confirm it picks the track back up.
        let resumeIndex = engine.selectedIndex
        engine.seek(toMs: 800)
        await settle(1)
        engine.shutdown()
        await settle(1)

        let engine2 = PlayerEngine(library: library, defaults: defaults)
        engine2.start()
        await settle(2)
        check(engine2.selectedIndex == resumeIndex,
              "relaunch resumed track \(resumeIndex) (got \(engine2.selectedIndex))")
        check(engine2.positionMs > 400, "relaunch resumed near the saved position (\(engine2.positionMs)ms)")
        engine2.shutdown()

        print("\n\(failures == 0 ? "integration OK" : "\(failures) integration failure(s)")")
        return failures == 0 ? 0 : 1
    }

    private static func settle(_ seconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }
}
