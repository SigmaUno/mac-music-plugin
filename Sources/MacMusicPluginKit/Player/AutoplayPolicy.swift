import Foundation

/// Pluggable randomness so shuffle is deterministic in tests.
public protocol IndexRandomizer {
    /// A value in `0..<upperBound`.
    func randomIndex(upperBound: Int) -> Int
}

public struct SystemRandomizer: IndexRandomizer {
    public init() {}
    public func randomIndex(upperBound: Int) -> Int { Int.random(in: 0..<upperBound) }
}

/// Pure next-track selection. Ports `next_autoplay_index` (backend/app.c:2551)
/// and the queue-first rule of `take_next_index` (backend/app.c:2585).
public enum AutoplayPolicy {
    /// The track autoplay moves to from `from`, ignoring the queue.
    ///
    /// - `from`: current row, or any value `>= count` for "nothing playing".
    /// - `allowRepeat`: when false, repeat-one still advances (so skipping past a
    ///   broken source works); the track-end path passes true.
    public static func nextIndex(count: Int, from: Int,
                                 shuffle: Bool, repeatOne: Bool, allowRepeat: Bool,
                                 randomizer: IndexRandomizer = SystemRandomizer()) -> Int {
        precondition(count > 0)
        if from >= count { return 0 }
        if count == 1 { return from }
        if allowRepeat && repeatOne { return from }
        if shuffle {
            var r = randomizer.randomIndex(upperBound: count)
            while r == from { r = randomizer.randomIndex(upperBound: count) }
            return r
        }
        return (from + 1) % count
    }

    /// The queue head if usable, otherwise the autoplay rule. Mutates `queue`.
    public static func takeNext(count: Int, from: Int, queue: inout PlayQueue,
                                shuffle: Bool, repeatOne: Bool, allowRepeat: Bool,
                                randomizer: IndexRandomizer = SystemRandomizer()) -> Int {
        if let head = queue.takeValidHead(count: count) { return head }
        return nextIndex(count: count, from: from, shuffle: shuffle,
                         repeatOne: repeatOne, allowRepeat: allowRepeat, randomizer: randomizer)
    }

    /// Linear step for prev/next buttons that bypass queue + shuffle. `delta` is
    /// ±1; wraps. Mirrors the tail of `play_library_relative` (backend/app.c:2612).
    public static func step(count: Int, from: Int, delta: Int) -> Int {
        precondition(count > 0)
        if from >= count { return delta > 0 ? 0 : count - 1 }
        let next = (from + delta) % count
        return next < 0 ? next + count : next
    }
}

/// Backoff for consecutive autoplay fetch failures. Ports
/// `autoplay_note_failure` / `autoplay_retry_delay_ms` (backend/app.c:2801).
public struct AutoplayBackoff: Equatable, Sendable {
    public private(set) var streak = 0

    public init() {}

    /// Records a failure. Returns true when a whole playlist's worth have failed
    /// back-to-back — every source is dead, so autoplay should halt.
    public mutating func recordFailure(playlistCount: Int) -> Bool {
        streak += 1
        return playlistCount > 0 && streak >= playlistCount
    }

    /// Clears the streak — a track actually started, or the user pressed play.
    public mutating func recordSuccess() { streak = 0 }

    /// Delay before the next attempt: first two retry immediately, then
    /// 500ms → 1s → 2s → 4s → 8s → 15s cap.
    public var retryDelay: Duration {
        guard streak > 2 else { return .zero }
        let shift = min(streak - 3, 5)
        let ms = min(500 << shift, 15_000)
        return .milliseconds(ms)
    }
}
