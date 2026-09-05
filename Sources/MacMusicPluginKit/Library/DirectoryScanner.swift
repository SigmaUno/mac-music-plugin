import Foundation

/// Turns a directory (local, or remote over `ssh`) into a list of staged
/// `Track`s — one `.local` / `.ssh` / `.network` source each, title taken from
/// the file name, artist/album left as "Unknown …". Ports `scan_worker`
/// (backend/app.c:3301): the scan stages tracks quickly without probing every
/// file; the user backfills real tags after accepting them.
public struct DirectoryScanner: Sendable {
    private let fetcher: RemoteFetcher
    private let controlDirectory: URL?

    public init(fetcher: RemoteFetcher = SystemRemoteFetcher(),
                controlDirectory: URL? = Paths.sshControl) {
        self.fetcher = fetcher
        self.controlDirectory = controlDirectory
    }

    static let audioExtensions: Set<String> =
        ["mp3", "flac", "ogg", "oga", "opus", "wav", "m4a", "aac", "wma"]

    /// True when `name` ends in a recognised audio extension. Mirrors
    /// `is_audio_name` (backend/app.c:1440).
    public static func isAudioName(_ name: String) -> Bool {
        audioExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    static func track(forPath path: String, source: Source) -> Track {
        let base = (path as NSString).lastPathComponent
        let title = (base as NSString).deletingPathExtension
        return Track(title: title.isEmpty ? base : title,
                     artist: "Unknown artist", album: "Unknown album",
                     sources: [source])
    }

    /// Files one level under a local directory, sorted, as `.local` staged tracks.
    public func scanLocal(directory: String) -> [Track] {
        let dir = (directory as NSString).expandingTildeInPath
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names
            .filter { !$0.hasPrefix(".") && Self.isAudioName($0) }
            .sorted()
            .compactMap { name in
                let full = (dir as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue
                else { return nil }
                return Self.track(forPath: full, source: Source(kind: .local, path: full))
            }
    }

    public enum ScanError: Error, Equatable {
        case invalidIdentity
        case transport(String)
    }

    /// Files one level under a remote directory, via `ssh … find`, as `.ssh` or
    /// `.network` staged tracks.
    public func scanRemote(kind: SourceKind, username: String, host: String,
                           directory: String) async throws -> [Track] {
        guard kind == .ssh || kind == .network,
              let argv = RemoteCommand.sshFind(username: username, ip: host, directory: directory,
                                               controlDirectory: controlDirectory)
        else { throw ScanError.invalidIdentity }

        let listing = ScratchFile.url(for: Source(kind: kind, path: "scan:\(directory)",
                                                  username: username, ip: host))
        defer { try? FileManager.default.removeItem(at: listing) }
        do {
            try await fetcher.run(argv: argv, destination: listing, maxBytes: 4 << 20)
        } catch let e as TrackLoadError {
            // `find` with no matches exits 0 but prints nothing — an empty scan,
            // not a failure.
            if case .transport(let m) = e {
                if m.contains("no data") { return [] }
                throw ScanError.transport(m)
            }
            if case .cancelled = e { throw ScanError.transport("cancelled") }
            throw ScanError.transport("\(e)")
        }

        let text = (try? String(contentsOf: listing, encoding: .utf8)) ?? ""
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { path in
                Self.track(forPath: path,
                           source: Source(kind: kind, path: path, username: username, ip: host))
            }
    }
}
