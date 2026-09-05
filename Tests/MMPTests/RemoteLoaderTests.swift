import Foundation
@testable import MacMusicPluginKit

/// Records the argv it is handed and replays a scripted result. `writesData`
/// makes it also create the destination file, so the "reuse existing download"
/// path can be exercised.
final class FakeRemoteFetcher: RemoteFetcher, @unchecked Sendable {
    struct Call: Sendable { let argv: [String]; let destination: URL; let maxBytes: Int }

    // The harness runs one case at a time and only reads `calls` after the
    // awaited load returns, so no locking is needed (mirrors Harness's own
    // `nonisolated(unsafe)` failure list).
    nonisolated(unsafe) private(set) var calls: [Call] = []

    private let error: TrackLoadError?
    private let writesData: Bool

    init(failWith error: TrackLoadError? = nil, writesData: Bool = false) {
        self.error = error
        self.writesData = writesData
    }

    func run(argv: [String], destination: URL, maxBytes: Int) async throws {
        calls.append(Call(argv: argv, destination: destination, maxBytes: maxBytes))
        if let error { throw error }
        if writesData {
            try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? Data("audio".utf8).write(to: destination)
        }
    }
}

/// A `MetadataReading` that ignores the file and always reports the same tags,
/// so a prober test can assert the fetch happened without a real tagged file.
struct EchoReader: MetadataReading {
    func read(_ url: URL) async -> ExtractedMetadata {
        ExtractedMetadata(title: "Echoed Title", artist: "Echoed Artist", album: "Echoed Album")
    }
}

/// Runs an async throwing body to completion on a background task, blocking the
/// caller — the harness is synchronous.
private func await_<T>(_ body: @escaping @Sendable () async throws -> T) -> Result<T, Error> {
    let sema = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    Task {
        do { box.value = .success(try await body()) }
        catch { box.value = .failure(error) }
        sema.signal()
    }
    sema.wait()
    return box.value!
}
private final class ResultBox<T>: @unchecked Sendable { var value: Result<T, Error>? }

enum RemoteLoaderTests {
    static func register() {
        Harness.test("isValidName: alnum + . - _, colon only for hosts") {
            Harness.expect(RemoteCommand.isValidName("kevin", allowColon: false), "plain user ok")
            Harness.expect(RemoteCommand.isValidName("nas-01.local", allowColon: true), "host with dot/dash ok")
            Harness.expect(RemoteCommand.isValidName("fe80::1", allowColon: true), "IPv6 literal ok as host")
            Harness.expect(!RemoteCommand.isValidName("fe80::1", allowColon: false), "colon rejected for user")
            Harness.expect(!RemoteCommand.isValidName("a b", allowColon: true), "space rejected")
            Harness.expect(!RemoteCommand.isValidName("a;rm -rf", allowColon: true), "metacharacters rejected")
            Harness.expect(!RemoteCommand.isValidName("user@host", allowColon: true), "@ rejected")
            Harness.expect(!RemoteCommand.isValidName("", allowColon: true), "empty rejected")
        }

        Harness.test("singleQuoted escapes embedded quotes for the remote shell") {
            Harness.expectEqual(RemoteCommand.singleQuoted("/music/a.flac"), "'/music/a.flac'")
            Harness.expectEqual(RemoteCommand.singleQuoted("a'b"), "'a'\\''b'")
            Harness.expectEqual(RemoteCommand.remoteCat(path: "/m/x; rm -rf ~"),
                                "cat -- '/m/x; rm -rf ~'", "injection stays one literal argument")
        }

        Harness.test("sshCat argv: hardening, -F /dev/null, control path, target, remote cmd") {
            let dir = URL(fileURLWithPath: "/tmp/mmp-ssh")
            let argv = RemoteCommand.sshCat(username: "kevin", ip: "10.0.0.5",
                                            remotePath: "/music/a.flac", controlDirectory: dir)!
            Harness.expectEqual(argv.first, "ssh")
            Harness.expect(argv.contains("-F") && argv.contains("/dev/null"), "ignores ~/.ssh/config")
            Harness.expect(adjacent(argv, "-o", "BatchMode=yes"), "batch mode")
            Harness.expect(adjacent(argv, "-o", "ConnectTimeout=5"), "connect timeout")
            Harness.expect(adjacent(argv, "-o", "ControlMaster=auto"), "multiplexing on")
            Harness.expect(argv.contains("-o") && argv.contains("ControlPath=/tmp/mmp-ssh/cm-%C"),
                           "control socket under the given dir")
            Harness.expectEqual(argv[argv.count - 3], "--")
            Harness.expectEqual(argv[argv.count - 2], "kevin@10.0.0.5")
            Harness.expectEqual(argv[argv.count - 1], "cat -- '/music/a.flac'")
        }

        Harness.test("sshCat: nil on invalid identity, control opts omitted when no dir") {
            Harness.expect(RemoteCommand.sshCat(username: "a b", ip: "10.0.0.5", remotePath: "/x") == nil,
                           "bad username rejected")
            Harness.expect(RemoteCommand.sshCat(username: "u", ip: "1.2.3.4", remotePath: "") == nil,
                           "empty path rejected")
            let argv = RemoteCommand.sshCat(username: "u", ip: "1.2.3.4", remotePath: "/x",
                                            controlDirectory: nil)!
            Harness.expect(!argv.contains("ControlMaster=auto"), "no multiplexing without a dir")
        }

        Harness.test("sshHead argv: bounded prefix fetch via head -c") {
            Harness.expectEqual(RemoteCommand.remoteHead(path: "/m/a.flac", bytes: 2048),
                                "head -c 2048 -- '/m/a.flac'")
            Harness.expectEqual(RemoteCommand.remoteHead(path: "a'b.flac", bytes: 10),
                                "head -c 10 -- 'a'\\''b.flac'", "path still single-quoted")
            let argv = RemoteCommand.sshHead(username: "kevin", ip: "10.0.0.5",
                                             remotePath: "/m/a.flac", bytes: 4096,
                                             controlDirectory: nil)!
            Harness.expectEqual(argv.first, "ssh")
            Harness.expectEqual(argv.last, "head -c 4096 -- '/m/a.flac'")
            Harness.expect(RemoteCommand.sshHead(username: "a b", ip: "h", remotePath: "/x", bytes: 1) == nil,
                           "bad identity rejected")
        }

        Harness.test("SystemMetadataProber: heads the file, reads tags; local source is skipped") {
            let (dir, cleanup) = Harness.tempDir("probe")
            defer { cleanup() }
            let fetcher = FakeRemoteFetcher(writesData: true)
            let prober = SystemMetadataProber(fetcher: fetcher, reader: EchoReader(),
                                              controlDirectory: nil, scratchRoot: dir, prefixBytes: 1234)

            let ssh = Source(kind: .ssh, path: "/m/a.flac", username: "u", ip: "1.2.3.4")
            let got = await_ { await prober.probe(ssh) }
            guard case .success(let meta) = got else { Harness.expect(false, "probe ran"); return }
            Harness.expectEqual(meta.artist, "Echoed Artist")
            Harness.expectEqual(fetcher.calls.count, 1)
            Harness.expect(fetcher.calls[0].argv.last == "head -c 1234 -- '/m/a.flac'", "bounded head fetch")

            let local = await_ { await prober.probe(Source(kind: .local, path: "/x.flac")) }
            if case .success(let m) = local { Harness.expect(m.isEmpty, "local source not probed") }
            Harness.expectEqual(fetcher.calls.count, 1, "no extra fetch for the local source")
        }

        Harness.test("curl argv: https-only, fail-fast, url last after --") {
            Harness.expect(RemoteCommand.curl(url: "http://example.com/a.mp3") == nil, "http rejected")
            Harness.expect(RemoteCommand.curl(url: "ftp://example.com/a.mp3") == nil, "ftp rejected")
            let argv = RemoteCommand.curl(url: "https://cdn.example.com/track.flac")!
            Harness.expectEqual(argv.first, "curl")
            Harness.expect(argv.contains("--fail"), "--fail")
            Harness.expect(adjacent(argv, "--proto", "=https"), "proto pinned to https")
            Harness.expect(adjacent(argv, "--output", "-"), "body to stdout")
            Harness.expectEqual(argv[argv.count - 2], "--")
            Harness.expectEqual(argv.last, "https://cdn.example.com/track.flac")
        }

        Harness.test("ScratchFile.url: stable per source, distinct across sources, carries extension") {
            let a = Source(kind: .https, url: "https://x.example/song.flac")
            let b = Source(kind: .https, url: "https://x.example/other.mp3")
            let root = URL(fileURLWithPath: "/tmp/mmp-scratch")
            Harness.expectEqual(ScratchFile.url(for: a, root: root), ScratchFile.url(for: a, root: root))
            Harness.expect(ScratchFile.url(for: a, root: root) != ScratchFile.url(for: b, root: root),
                           "different URL => different scratch file")
            Harness.expect(ScratchFile.url(for: a, root: root).pathExtension == "flac", "extension carried")
            let ssh = Source(kind: .ssh, path: "/m/a.wav", username: "u", ip: "1.2.3.4")
            Harness.expect(ScratchFile.url(for: ssh, root: root).pathExtension == "wav", "ssh path extension carried")
        }

        Harness.test("ScratchFile.prune keeps only the named sources") {
            let (dir, cleanup) = Harness.tempDir("prune")
            defer { cleanup() }
            let keep = Source(kind: .https, url: "https://x/keep.mp3")
            let drop = Source(kind: .https, url: "https://x/drop.mp3")
            for s in [keep, drop] { try Data("x".utf8).write(to: ScratchFile.url(for: s, root: dir)) }
            try Data("x".utf8).write(to: dir.appendingPathComponent("stray.tmp"))
            ScratchFile.prune(keeping: [keep], root: dir)
            Harness.expect(FileManager.default.fileExists(atPath: ScratchFile.url(for: keep, root: dir).path),
                           "kept file survives")
            Harness.expect(!FileManager.default.fileExists(atPath: ScratchFile.url(for: drop, root: dir).path),
                           "unnamed download removed")
            Harness.expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("stray.tmp").path),
                           "stray file removed")
        }

        Harness.test("HTTPSTrackLoader: downloads to scratch, runs curl, rejects non-https") {
            let (dir, cleanup) = Harness.tempDir("https")
            defer { cleanup() }
            let fetcher = FakeRemoteFetcher()
            let loader = HTTPSTrackLoader(fetcher: fetcher, scratchRoot: dir)
            let src = Source(kind: .https, url: "https://cdn.example/a.flac")

            let ok = await_ { try await loader.load(src) }
            guard case .success(let url) = ok else { Harness.expect(false, "expected success"); return }
            Harness.expectEqual(url.deletingLastPathComponent().path, dir.path)
            Harness.expectEqual(fetcher.calls.count, 1)
            Harness.expectEqual(fetcher.calls[0].argv.first, "curl")
            Harness.expectEqual(fetcher.calls[0].destination, url)

            let bad = await_ { try await loader.load(Source(kind: .https, url: "http://cdn.example/a.flac")) }
            if case .failure(let e) = bad { Harness.expect(e is TrackLoadError, "http rejected") }
            else { Harness.expect(false, "expected http:// to fail") }
        }

        Harness.test("HTTPSTrackLoader: reuses an existing non-empty download") {
            let (dir, cleanup) = Harness.tempDir("https-reuse")
            defer { cleanup() }
            let fetcher = FakeRemoteFetcher(writesData: true)
            let loader = HTTPSTrackLoader(fetcher: fetcher, scratchRoot: dir)
            let src = Source(kind: .https, url: "https://cdn.example/a.flac")
            _ = await_ { try await loader.load(src) }
            _ = await_ { try await loader.load(src) }
            Harness.expectEqual(fetcher.calls.count, 1, "second load hits the cached file, no re-fetch")
        }

        Harness.test("SSHTrackLoader: serves ssh and network, rejects bad identity") {
            let (dir, cleanup) = Harness.tempDir("ssh")
            defer { cleanup() }
            let fetcher = FakeRemoteFetcher()
            let loader = SSHTrackLoader(fetcher: fetcher, controlDirectory: nil, scratchRoot: dir)

            for kind in [SourceKind.ssh, .network] {
                let src = Source(kind: kind, path: "/m/a.flac", username: "kevin", ip: "10.0.0.5")
                let r = await_ { try await loader.load(src) }
                Harness.expect({ if case .success = r { return true } else { return false } }(),
                               "\(kind) source loads")
            }
            Harness.expectEqual(fetcher.calls.count, 2)
            Harness.expectEqual(fetcher.calls[0].argv.first, "ssh")

            let bad = await_ {
                try await loader.load(Source(kind: .ssh, path: "/m/a.flac", username: "k;id", ip: "10.0.0.5"))
            }
            if case .failure(let e) = bad { Harness.expect(e is TrackLoadError, "bad username rejected") }
            else { Harness.expect(false, "expected invalid username to fail") }
        }

        Harness.test("FallbackTrackLoader: skips a failing ssh source for a working https one") {
            let (dir, cleanup) = Harness.tempDir("fallback")
            defer { cleanup() }
            let ssh = SSHTrackLoader(fetcher: FakeRemoteFetcher(failWith: .transport("host down")),
                                     controlDirectory: nil, scratchRoot: dir)
            let https = HTTPSTrackLoader(fetcher: FakeRemoteFetcher(), scratchRoot: dir)
            let fallback = FallbackTrackLoader(loaders: [.ssh: ssh, .network: ssh, .https: https])

            let track = Track(title: "T", artist: "A", album: "R", sources: [
                Source(kind: .ssh, path: "/m/a.flac", username: "u", ip: "1.2.3.4"),
                Source(kind: .https, url: "https://cdn.example/a.flac"),
            ])
            let r = await_ { try await fallback.loadTrack(track) }
            guard case .success(let (_, source)) = r else { Harness.expect(false, "expected a source to load"); return }
            Harness.expectEqual(source.kind, .https, "fell through to the https source")
        }

        Harness.test("FallbackTrackLoader: a cancelled fetch aborts, no fallthrough") {
            let (dir, cleanup) = Harness.tempDir("fallback-cancel")
            defer { cleanup() }
            let ssh = SSHTrackLoader(fetcher: FakeRemoteFetcher(failWith: .cancelled),
                                     controlDirectory: nil, scratchRoot: dir)
            let https = HTTPSTrackLoader(fetcher: FakeRemoteFetcher(), scratchRoot: dir)
            let fallback = FallbackTrackLoader(loaders: [.ssh: ssh, .https: https])
            let track = Track(title: "T", artist: "A", album: "R", sources: [
                Source(kind: .ssh, path: "/m/a.flac", username: "u", ip: "1.2.3.4"),
                Source(kind: .https, url: "https://cdn.example/a.flac"),
            ])
            let r = await_ { try await fallback.loadTrack(track) }
            if case .failure(let e) = r { Harness.expectEqual(e as? TrackLoadError, .cancelled) }
            else { Harness.expect(false, "cancellation should propagate, not fall through") }
        }

        Harness.test("SSHAgent.unlock reports terminal open / failure via the injected runner") {
            Harness.expectEqual(SSHAgent.unlock(runner: { _ in true }), .openedTerminal)
            if case .failed = SSHAgent.unlock(runner: { _ in false }) {} else {
                Harness.expect(false, "a failing runner should surface .failed")
            }
        }
    }

    /// True when `b` immediately follows `a` somewhere in `argv` (an `-o K=V` pair).
    private static func adjacent(_ argv: [String], _ a: String, _ b: String) -> Bool {
        for i in argv.indices.dropLast() where argv[i] == a && argv[i + 1] == b { return true }
        return false
    }
}
