import Foundation

/// Runs one fetch subprocess (`curl` or `ssh`), streaming its stdout into a
/// local file. The seam the remote loaders are built on: `SystemRemoteFetcher`
/// spawns a real process; tests inject a stub.
public protocol RemoteFetcher: Sendable {
    /// Spawns `argv[0]` with `argv[1...]`, writing everything it prints to
    /// stdout into `destination` (truncating it first). Returns when the process
    /// exits 0 and the file is complete.
    ///
    /// - Parameter maxBytes: fail rather than let the file grow past this — a
    ///   stuck source that streams forever must not fill the disk.
    /// - Throws: `TrackLoadError.transport` on non-zero exit, a spawn failure, or
    ///   the size cap; `TrackLoadError.cancelled` if the task is cancelled.
    func run(argv: [String], destination: URL, maxBytes: Int) async throws
}

public extension RemoteFetcher {
    /// 3 GiB, matching the C fetch buffer cap (backend/app.c `start_fetch`).
    /// Generous enough that a legitimate lossless file always fits.
    static var defaultMaxBytes: Int { 3 * 1024 * 1024 * 1024 }
}

/// Spawns the fetch process with `Foundation.Process`, pumping its stdout pipe
/// to `destination` on a background queue. Cancelling the surrounding `Task`
/// terminates the process (SIGTERM, then SIGKILL) so a hung `ssh`/`curl` never
/// wedges a track change — the same guarantee the C code gets from
/// `kill(pid, SIGTERM)` in `join_fetch_thread`.
public struct SystemRemoteFetcher: RemoteFetcher {
    public init() {}

    public func run(argv: [String], destination: URL, maxBytes: Int) async throws {
        precondition(!argv.isEmpty)
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: destination) else {
            throw TrackLoadError.transport("cannot open scratch file")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardInput = FileHandle.nullDevice
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            try? handle.close()
            throw TrackLoadError.transport("could not start \(argv[0]): \(error.localizedDescription)")
        }

        // One dedicated thread owns the stdout pipe end to end: read it to EOF
        // (which the kernel signals once the process exits or is terminated),
        // then reap the process. No `readabilityHandler`, so the fd is never
        // touched from two places. Cancelling the task calls `terminate()`,
        // which closes the pipe and unblocks the read.
        let sink = Sink(handle: handle, maxBytes: maxBytes)
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                Thread.detachNewThread {
                    let reader = stdout.fileHandleForReading
                    while let chunk = try? reader.read(upToCount: 256 * 1024), !chunk.isEmpty {
                        if !sink.write(chunk) { process.terminate(); break }
                    }
                    process.waitUntilExit()
                    continuation.resume()
                }
            }
        } onCancel: {
            process.terminate()
        }

        sink.close()
        let written = sink.byteCount
        let overflowed = sink.overflowed

        let errText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if Task.isCancelled {
            try? FileManager.default.removeItem(at: destination)
            throw TrackLoadError.cancelled
        }
        if overflowed {
            try? FileManager.default.removeItem(at: destination)
            throw TrackLoadError.transport("source exceeded \(maxBytes / (1024 * 1024)) MB")
        }
        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: destination)
            let detail = errText.isEmpty ? "exit \(process.terminationStatus)" : errText
            throw TrackLoadError.transport(Self.firstLine(of: detail))
        }
        guard written > 0 else {
            try? FileManager.default.removeItem(at: destination)
            throw TrackLoadError.transport("source returned no data")
        }
    }

    private static func firstLine(of text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }
}

/// Serialises writes to the scratch file and enforces the byte cap. Every method
/// is synchronous so its `NSLock` use is legal from both the Foundation
/// readability queue and the fetch task.
private final class Sink: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let maxBytes: Int
    private var written = 0
    private var overflow = false
    private var closed = false

    init(handle: FileHandle, maxBytes: Int) {
        self.handle = handle
        self.maxBytes = maxBytes
    }

    /// Appends `data`; returns false once the cap is hit (caller should stop the
    /// producer). A no-op on empty data or after `close()`.
    func write(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        lock.lock()
        defer { lock.unlock() }
        guard !closed, !overflow else { return !overflow }
        if written + data.count > maxBytes {
            overflow = true
            return false
        }
        try? handle.write(contentsOf: data)
        written += data.count
        return true
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        try? handle.close()
    }

    var byteCount: Int { lock.lock(); defer { lock.unlock() }; return written }
    var overflowed: Bool { lock.lock(); defer { lock.unlock() }; return overflow }
}
