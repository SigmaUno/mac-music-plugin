import CryptoKit
import Foundation

/// Names and locates the scratch file a remote source is downloaded to. The name
/// is derived from `Source.dedupKey`, so re-playing the same source within a run
/// reuses the file instead of re-downloading, and two different sources never
/// collide. Everything lives under `Paths.scratch`, which is wiped on launch and
/// quit (`Paths.clearVolatile`).
enum ScratchFile {
    static func url(for source: Source, root: URL = Paths.scratch) -> URL {
        let digest = SHA256.hash(data: Data(source.dedupKey.utf8))
        let stem = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("\(stem)\(extensionHint(for: source))")
    }

    /// Carries the source's file extension onto the scratch file. `AVAudioFile`
    /// sniffs content, not names, so this is only a debugging nicety — except for
    /// extension-less HTTPS stream URLs, where there is nothing to carry.
    private static func extensionHint(for source: Source) -> String {
        let name = source.kind == .https ? (source.url ?? "") : (source.path ?? "")
        let ext = (name as NSString).pathExtension.lowercased()
        let known = ["mp3", "flac", "ogg", "wav", "m4a", "aac", "opus", "wma"]
        return known.contains(ext) ? ".\(ext)" : ""
    }

    /// Removes every scratch file except the ones backing `keep`. Called when a
    /// new remote track starts so at most a couple of downloads sit on disk.
    static func prune(keeping keep: [Source], root: URL = Paths.scratch) {
        let survivors = Set(keep.map { url(for: $0, root: root).lastPathComponent })
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for entry in entries where !entry.hasPrefix(".") && !survivors.contains(entry) {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(entry))
        }
    }
}

/// Streams an `https://` source to a scratch file with `curl`. Mirrors
/// `stream_https` (backend/app.c:993).
public struct HTTPSTrackLoader: TrackLoader {
    private let fetcher: RemoteFetcher
    private let maxBytes: Int
    private let scratchRoot: URL

    public init(fetcher: RemoteFetcher = SystemRemoteFetcher(),
                maxBytes: Int = SystemRemoteFetcher.defaultMaxBytes,
                scratchRoot: URL = Paths.scratch) {
        self.fetcher = fetcher
        self.maxBytes = maxBytes
        self.scratchRoot = scratchRoot
    }

    public func load(_ source: Source) async throws -> URL {
        guard source.kind == .https else { throw TrackLoadError.unsupportedKind(source.kind) }
        guard let url = source.url, let argv = RemoteCommand.curl(url: url) else {
            throw TrackLoadError.transport("only https:// URLs are supported")
        }
        let destination = ScratchFile.url(for: source, root: scratchRoot)
        if isNonEmptyFile(destination) { return destination }
        try Task.checkCancellation()
        try await fetcher.run(argv: argv, destination: destination, maxBytes: maxBytes)
        return destination
    }
}

/// Streams an `ssh` or local-network source to a scratch file by running
/// `cat` on the remote host over `ssh`. The two kinds are identical on the wire
/// — they differ only in how they are labelled and in the local-network TCC
/// prompt macOS shows for `network`. Mirrors `stream_ssh` (backend/app.c:962),
/// which likewise serves both `LIBRARY_SOURCE_SSH` and `LIBRARY_SOURCE_NETWORK`.
public struct SSHTrackLoader: TrackLoader {
    private let fetcher: RemoteFetcher
    private let maxBytes: Int
    private let controlDirectory: URL?
    private let scratchRoot: URL

    public init(fetcher: RemoteFetcher = SystemRemoteFetcher(),
                maxBytes: Int = SystemRemoteFetcher.defaultMaxBytes,
                controlDirectory: URL? = Paths.sshControl,
                scratchRoot: URL = Paths.scratch) {
        self.fetcher = fetcher
        self.maxBytes = maxBytes
        self.controlDirectory = controlDirectory
        self.scratchRoot = scratchRoot
    }

    public func load(_ source: Source) async throws -> URL {
        guard source.kind == .ssh || source.kind == .network else {
            throw TrackLoadError.unsupportedKind(source.kind)
        }
        guard let username = source.username, let ip = source.ip, let path = source.path,
              let argv = RemoteCommand.sshCat(username: username, ip: ip, remotePath: path,
                                              controlDirectory: controlDirectory) else {
            throw TrackLoadError.transport("USERNAME, IP and PATH are required and must be valid")
        }
        let destination = ScratchFile.url(for: source, root: scratchRoot)
        if isNonEmptyFile(destination) { return destination }
        try Task.checkCancellation()
        try await fetcher.run(argv: argv, destination: destination, maxBytes: maxBytes)
        return destination
    }
}

private func isNonEmptyFile(_ url: URL) -> Bool {
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attrs?[.size] as? Int ?? 0) > 0
}
