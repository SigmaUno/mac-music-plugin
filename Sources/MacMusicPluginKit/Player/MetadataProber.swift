import Foundation

/// Reads the tags (and, when they fit in the fetched prefix, the embedded cover)
/// of a *remote* source without downloading the whole track. Used to backfill a
/// playlist's "Unknown artist / Unknown album" rows the moment it is viewed,
/// rather than waiting for each track to be played.
///
/// A protocol so the engine's on-view backfill is testable without a network.
public protocol MetadataProbing: Sendable {
    /// Best-effort: returns empty metadata for a local/https source, an
    /// unreachable host, a file with no tags, or a cancelled task.
    func probe(_ source: Source) async -> ExtractedMetadata
}

/// `ssh … "head -c N"` to a temp file, then `AVMetadataReader`. Reuses a
/// complete scratch download if the track has already been played this run.
public struct SystemMetadataProber: MetadataProbing {
    /// How much of each file to pull. Covers the tag blocks of every format and,
    /// for most files, the front-cover `PICTURE` too; a cover past this is still
    /// picked up when the track is played (`PlayerEngine.backfillNowPlaying`).
    public static let prefixBytes = 2 * 1024 * 1024

    private let fetcher: RemoteFetcher
    private let reader: MetadataReading
    private let controlDirectory: URL?
    private let scratchRoot: URL
    private let prefixBytes: Int

    public init(fetcher: RemoteFetcher = SystemRemoteFetcher(),
                reader: MetadataReading = AVMetadataReader(),
                controlDirectory: URL? = Paths.sshControl,
                scratchRoot: URL = Paths.scratch,
                prefixBytes: Int = SystemMetadataProber.prefixBytes) {
        self.fetcher = fetcher
        self.reader = reader
        self.controlDirectory = controlDirectory
        self.scratchRoot = scratchRoot
        self.prefixBytes = prefixBytes
    }

    public func probe(_ source: Source) async -> ExtractedMetadata {
        guard source.kind == .ssh || source.kind == .network,
              let username = source.username, let ip = source.ip, let path = source.path,
              let argv = RemoteCommand.sshHead(username: username, ip: ip, remotePath: path,
                                               bytes: prefixBytes, controlDirectory: controlDirectory)
        else { return ExtractedMetadata() }

        // A full download from a previous play is the best source of truth.
        let full = ScratchFile.url(for: source, root: scratchRoot)
        let fullSize = (try? FileManager.default.attributesOfItem(atPath: full.path))?[.size] as? Int ?? 0
        if fullSize > 0 { return await reader.read(full) }

        // A throwaway prefix, kept out of the scratch dir so track-change
        // pruning never races it.
        let ext = (path as NSString).pathExtension.lowercased()
        let name = "mmp-probe-\(UUID().uuidString)" + (ext.isEmpty ? "" : ".\(ext)")
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: destination) }

        do {
            try Task.checkCancellation()
            try await fetcher.run(argv: argv, destination: destination, maxBytes: prefixBytes + 64 * 1024)
        } catch {
            return ExtractedMetadata()
        }
        return await reader.read(destination)
    }
}
