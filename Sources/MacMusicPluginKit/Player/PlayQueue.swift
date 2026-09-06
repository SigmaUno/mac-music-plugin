import Foundation

/// The ad-hoc "play next" list, consumed before playlist order. Bounded like the
/// C `play_queue` (cap 64). Mirrors `play_queue_push` / `play_queue_remove_at` /
/// `take_next_index` (backend/app.c:2568).
public struct PlayQueue: Equatable, Sendable {
    public static let capacity = 64

    public private(set) var indices: [Int] = []

    public init() {}

    public var isEmpty: Bool { indices.isEmpty }
    public var count: Int { indices.count }

    public mutating func push(_ index: Int) {
        guard indices.count < Self.capacity else { return }
        indices.append(index)
    }

    /// Removes the first queued occurrence of a library index.
    public mutating func remove(index: Int) {
        if let pos = indices.firstIndex(of: index) { indices.remove(at: pos) }
    }

    public mutating func clear() { indices.removeAll() }

    /// Pops queue heads until one still points at a real track (`< count`),
    /// returning it; nil when the queue holds nothing usable.
    public mutating func takeValidHead(count: Int) -> Int? {
        while !indices.isEmpty {
            let head = indices.removeFirst()
            if head < count { return head }
        }
        return nil
    }

    /// Keeps entries valid after a track at `removedIndex` leaves the playlist:
    /// drop it, shift entries above it down by one. Mirrors the queue-fixup loop
    /// in `note_removed_row` (backend/app.c:2934).
    public mutating func compact(afterRemoving removedIndex: Int) {
        var result: [Int] = []
        for i in indices where i != removedIndex {
            result.append(i > removedIndex ? i - 1 : i)
        }
        indices = result
    }

    /// 1-based position of a library index in the queue, or 0 if absent.
    /// Mirrors `queuePosition` (BarWidget.qml:186).
    public func position(of index: Int) -> Int {
        (indices.firstIndex(of: index).map { $0 + 1 }) ?? 0
    }
}
