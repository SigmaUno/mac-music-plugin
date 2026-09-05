import AVFoundation
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

        for path in files {
            try? await engine.addLocalFile(path: path)
        }
        check(engine.viewedTracks.count == files.count, "added \(files.count) tracks to home")

        // Play the first track.
        engine.playFromViewed(0)
        await settle(1.5)
        check(engine.isPlaying, "playing after playFromViewed(0)")
        check(engine.durationMs > 3000, "duration read (\(engine.durationMs)ms)")
        check(engine.selectedIndex == 0, "selectedIndex == 0")
        print("       now-playing cover: \(engine.coverPath.map { "embedded art -> \($0)" } ?? "none")")
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

    /// Fetches one HTTPS source (and, if `sshTarget` is `user@host:/path`, one
    /// SSH source) through the real `curl` / `ssh` subprocesses, then confirms
    /// AVFoundation can open the scratch file.
    @MainActor
    static func runRemote(httpsURL: String, sshTarget: String?) async -> Int {
        var failures = 0
        func check(_ cond: Bool, _ msg: String) {
            print(cond ? "  ok   \(msg)" : "  FAIL \(msg)")
            if !cond { failures += 1 }
        }

        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("mmp-remote-\(UUID().uuidString)")
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        var sources: [(String, Source)] = [
            ("https", Source(kind: .https, url: httpsURL)),
        ]
        if let sshTarget, let at = sshTarget.firstIndex(of: "@"), let colon = sshTarget.firstIndex(of: ":") {
            let user = String(sshTarget[sshTarget.startIndex..<at])
            let host = String(sshTarget[sshTarget.index(after: at)..<colon])
            let path = String(sshTarget[sshTarget.index(after: colon)...])
            sources.append(("ssh", Source(kind: .ssh, path: path, username: user, ip: host)))
        }

        let loader = FallbackTrackLoader.standard()
        for (label, source) in sources {
            let track = Track(title: label, artist: "T", album: "Remote", sources: [source])
            do {
                let started = Date()
                let (url, used) = try await loader.loadTrack(track)
                let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
                check(used.kind == source.kind, "\(label): used the \(source.kind) source")
                check(size > 10_000, "\(label): downloaded \(size / 1024) KB to scratch")
                let file = try AVAudioFile(forReading: url)
                check(file.length > 0, "\(label): AVFoundation opened it (\(file.length) frames)")
                print("       \(label) fetched in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
            } catch {
                check(false, "\(label): \(error)")
            }
        }

        print("\n\(failures == 0 ? "remote integration OK" : "\(failures) remote failure(s)")")
        return failures == 0 ? 0 : 1
    }

    /// Reads tags + embedded art from each file with the real `AVMetadataReader`
    /// (which routes FLAC/Ogg through the native container parsers). Local only.
    static func runTags(files: [String]) async -> Int {
        let reader = AVMetadataReader()
        var failures = 0
        for path in files {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let m = await reader.read(url)
            let art = m.artwork.map { "\($0.count) B \(ImageKind.sniff($0).map { "\($0)" } ?? "unknown")" } ?? "none"
            print("  \(url.lastPathComponent)")
            print("    title:  \(m.title ?? "<none>")")
            print("    artist: \(m.artist ?? "<none>")")
            print("    album:  \(m.album ?? "<none>")")
            print("    art:    \(art)")
            if m.isEmpty { print("    FAIL: no metadata extracted"); failures += 1 }
        }
        print("\n\(failures == 0 ? "tags OK" : "\(failures) file(s) with no metadata")")
        return failures == 0 ? 0 : 1
    }

    /// Plays `audioFile`, reports any embedded artwork, then runs a real iTunes
    /// cover search + apply against the live service. Local only — needs network.
    @MainActor
    static func runCover(audioFile: String) async -> Int {
        var failures = 0
        func check(_ cond: Bool, _ msg: String) {
            print(cond ? "  ok   \(msg)" : "  FAIL \(msg)")
            if !cond { failures += 1 }
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("mmp-cover-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let library = LibraryStore(directory: root.appendingPathComponent("library"))
        try? library.bootstrap()
        let defaults = UserDefaults(suiteName: "mmp-cover-int-\(UUID().uuidString)")!
        let engine = PlayerEngine(library: library, defaults: defaults)
        engine.start()

        do { try await engine.addLocalFile(path: audioFile) } catch { check(false, "add: \(error)"); return 1 }
        let imported = engine.viewedTracks.last
        print("       imported tags: \(imported?.title ?? "?") / \(imported?.artist ?? "?") / \(imported?.album ?? "?")")

        engine.playFromViewed(engine.viewedTracks.count - 1)
        await settle(2)
        check(engine.selectedIndex >= 0, "playing the imported track")
        print("       embedded artwork: \(engine.coverPath ?? "none")")

        engine.searchCoverArt(query: "daft punk get lucky")
        for _ in 0..<40 where engine.isCoverBusy { await settle(0.25) }
        check(!engine.coverResults.isEmpty, "iTunes returned candidates (\(engine.coverResults.count))")
        print("       \(engine.coverStatus)")

        guard let first = engine.coverResults.first else {
            print("\n\(failures) cover failure(s)"); return failures == 0 ? 1 : failures
        }
        check(first.artworkURL.contains("600x600"), "artwork URL upscaled: \(first.artworkURL)")

        engine.applyCoverArt(first)
        for _ in 0..<40 where engine.isCoverBusy { await settle(0.25) }
        let cover = engine.viewedTracks.last?.cover
        check(cover != nil, "cover written to the library")
        check(cover.map { fm.fileExists(atPath: $0) } == true, "cover file on disk")
        check(cover.map { ImageKind.sniff((try? Data(contentsOf: URL(fileURLWithPath: $0))) ?? Data()) != nil } == true,
              "stored file is a real image")
        print("       \(engine.coverStatus)")

        engine.shutdown()
        print("\n\(failures == 0 ? "cover integration OK" : "\(failures) cover failure(s)")")
        return failures == 0 ? 0 : 1
    }
}
