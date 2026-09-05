import Foundation

public enum TrackLoadError: Error, Equatable {
    case noUsableSource
    case unsupportedKind(SourceKind)
    case fileNotFound(String)
    case cancelled
    case transport(String)
}

/// Resolves a `Source` to a local file URL that AVFoundation can open. Local
/// sources return their path directly; remote sources (added in milestone 4)
/// stream to a scratch file.
public protocol TrackLoader: Sendable {
    /// - Returns: a readable local file URL for the source's audio.
    func load(_ source: Source) async throws -> URL
}

/// Local files: hands AVFoundation the on-disk path directly, no copy.
public struct LocalTrackLoader: TrackLoader {
    public init() {}

    public func load(_ source: Source) async throws -> URL {
        guard source.kind == .local else { throw TrackLoadError.unsupportedKind(source.kind) }
        guard let path = source.path else { throw TrackLoadError.noUsableSource }
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw TrackLoadError.fileNotFound(expanded)
        }
        return URL(fileURLWithPath: expanded)
    }
}

/// Tries each of a track's sources in turn until one loads. Mirrors the
/// "first usable source" loop in `fetch_worker` (backend/app.c:2187), with the
/// remote fallback the C code lacks.
public struct FallbackTrackLoader: TrackLoader {
    private let loaders: [SourceKind: TrackLoader]

    public init(loaders: [SourceKind: TrackLoader]) {
        self.loaders = loaders
    }

    public static func local() -> FallbackTrackLoader {
        FallbackTrackLoader(loaders: [.local: LocalTrackLoader()])
    }

    /// Every source kind: local files direct, `https` via `curl`, `ssh` and
    /// `network` via `cat` over `ssh`. The default the app runs with.
    public static func standard(fetcher: RemoteFetcher = SystemRemoteFetcher()) -> FallbackTrackLoader {
        let ssh = SSHTrackLoader(fetcher: fetcher)
        return FallbackTrackLoader(loaders: [
            .local: LocalTrackLoader(),
            .https: HTTPSTrackLoader(fetcher: fetcher),
            .ssh: ssh,
            .network: ssh,
        ])
    }

    public func load(_ source: Source) async throws -> URL {
        guard let loader = loaders[source.kind] else { throw TrackLoadError.unsupportedKind(source.kind) }
        return try await loader.load(source)
    }

    public func loadTrack(_ track: Track) async throws -> (url: URL, source: Source) {
        var lastError: Error = TrackLoadError.noUsableSource
        for source in track.sources where source.isComplete {
            guard loaders[source.kind] != nil else { continue }
            do {
                let url = try await load(source)
                return (url, source)
            } catch {
                if error as? TrackLoadError == .cancelled { throw error }
                lastError = error
            }
        }
        throw lastError
    }
}
