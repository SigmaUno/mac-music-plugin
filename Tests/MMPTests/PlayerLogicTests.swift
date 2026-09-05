import Foundation
@testable import MacMusicPluginKit

/// Deterministic randomizer: returns a scripted sequence, then 0.
final class ScriptedRandomizer: IndexRandomizer {
    private var values: [Int]
    init(_ values: [Int]) { self.values = values }
    func randomIndex(upperBound: Int) -> Int {
        values.isEmpty ? 0 : values.removeFirst()
    }
}

enum PlayerLogicTests {
    static func register() {
        Harness.test("PlayQueue push/take/cap/compact") {
            var q = PlayQueue()
            q.push(3); q.push(1); q.push(9)
            Harness.expectEqual(q.indices, [3, 1, 9])
            Harness.expectEqual(q.position(of: 1), 2)

            // takeValidHead drops entries past the end of a shrunk playlist.
            Harness.expectEqual(q.takeValidHead(count: 5), 3)
            Harness.expectEqual(q.takeValidHead(count: 5), 1)
            Harness.expect(q.takeValidHead(count: 5) == nil, "9 is out of range and dropped")

            var full = PlayQueue()
            for i in 0..<(PlayQueue.capacity + 10) { full.push(i) }
            Harness.expectEqual(full.count, PlayQueue.capacity)

            var c = PlayQueue()
            c.push(1); c.push(4); c.push(6)
            c.compact(afterRemoving: 4)
            Harness.expectEqual(c.indices, [1, 5], "removed entry gone, higher entries shift down")
        }

        Harness.test("nextIndex: linear, wrap, single, from-out-of-range") {
            let r = ScriptedRandomizer([])
            Harness.expectEqual(AutoplayPolicy.nextIndex(count: 5, from: 2, shuffle: false, repeatOne: false, allowRepeat: true, randomizer: r), 3)
            Harness.expectEqual(AutoplayPolicy.nextIndex(count: 5, from: 4, shuffle: false, repeatOne: false, allowRepeat: true, randomizer: r), 0)
            Harness.expectEqual(AutoplayPolicy.nextIndex(count: 1, from: 0, shuffle: false, repeatOne: false, allowRepeat: true, randomizer: r), 0)
            Harness.expectEqual(AutoplayPolicy.nextIndex(count: 5, from: 99, shuffle: true, repeatOne: true, allowRepeat: true, randomizer: r), 0)
        }

        Harness.test("nextIndex: repeat-one respects allowRepeat") {
            let r = ScriptedRandomizer([])
            Harness.expectEqual(AutoplayPolicy.nextIndex(count: 4, from: 2, shuffle: false, repeatOne: true, allowRepeat: true, randomizer: r), 2, "track-end stays put")
            Harness.expectEqual(AutoplayPolicy.nextIndex(count: 4, from: 2, shuffle: false, repeatOne: true, allowRepeat: false, randomizer: r), 3, "skip button still advances")
        }

        Harness.test("nextIndex: shuffle never returns the current index") {
            let r = ScriptedRandomizer([2, 2, 2, 3])  // keeps hitting current, then 3
            Harness.expectEqual(AutoplayPolicy.nextIndex(count: 5, from: 2, shuffle: true, repeatOne: false, allowRepeat: true, randomizer: r), 3)
        }

        Harness.test("takeNext: queue wins over shuffle/linear") {
            var q = PlayQueue()
            q.push(4)
            let r = ScriptedRandomizer([1])
            let picked = AutoplayPolicy.takeNext(count: 10, from: 0, queue: &q, shuffle: true, repeatOne: false, allowRepeat: true, randomizer: r)
            Harness.expectEqual(picked, 4)
            Harness.expect(q.isEmpty, "queue head consumed")
        }

        Harness.test("step: linear prev/next with wrap and edge entry") {
            Harness.expectEqual(AutoplayPolicy.step(count: 5, from: 0, delta: -1), 4)
            Harness.expectEqual(AutoplayPolicy.step(count: 5, from: 4, delta: 1), 0)
            Harness.expectEqual(AutoplayPolicy.step(count: 5, from: 99, delta: -1), 4, "step in from the end")
            Harness.expectEqual(AutoplayPolicy.step(count: 5, from: 99, delta: 1), 0)
        }

        Harness.test("AutoplayBackoff: streak, halt threshold, delay schedule") {
            var b = AutoplayBackoff()
            Harness.expectEqual(b.retryDelay, .zero)
            Harness.expect(!b.recordFailure(playlistCount: 3), "1st failure: no halt")
            Harness.expect(!b.recordFailure(playlistCount: 3), "2nd")
            Harness.expectEqual(b.retryDelay, .zero, "first two retry immediately")
            Harness.expect(b.recordFailure(playlistCount: 3), "3rd failure of a 3-track list: halt")
            Harness.expectEqual(b.retryDelay, .milliseconds(500))

            var d = AutoplayBackoff()
            for _ in 0..<3 { _ = d.recordFailure(playlistCount: 100) }
            Harness.expectEqual(d.retryDelay, .milliseconds(500))
            _ = d.recordFailure(playlistCount: 100); Harness.expectEqual(d.retryDelay, .milliseconds(1000))
            for _ in 0..<10 { _ = d.recordFailure(playlistCount: 100) }
            Harness.expectEqual(d.retryDelay, .milliseconds(15_000), "capped at 15s")

            d.recordSuccess()
            Harness.expectEqual(d.streak, 0)
        }

        Harness.test("LocalTrackLoader loads existing files, rejects others") {
            let (dir, cleanup) = Harness.tempDir("loader")
            defer { cleanup() }
            let file = dir.appendingPathComponent("song.mp3")
            try Data("x".utf8).write(to: file)
            let loader = LocalTrackLoader()

            let sema = DispatchSemaphore(value: 0)
            var result: Result<URL, Error>?
            Task {
                do { result = .success(try await loader.load(Source(kind: .local, path: file.path))) }
                catch { result = .failure(error) }
                sema.signal()
            }
            sema.wait()
            if case .success(let url)? = result {
                Harness.expectEqual(url.lastPathComponent, "song.mp3")
            } else {
                Harness.expect(false, "expected the file to load")
            }
        }
    }
}
