import Foundation

// XCTest is unavailable under the Command Line Tools, so the suite is a plain
// executable. Each *Tests type registers its cases, then Harness.run() prints a
// summary and exits non-zero on failure.
//
// `swift run MMPTests --audio <dir>` instead runs the real-audio integration
// check (local only — CI runners have no output device).
//
// `swift run MMPTests --remote <https-url> [user@host:/remote/path]` exercises
// the real fetch subprocesses (curl, and ssh when a target is given), streaming
// each source to a scratch file and decoding it. Local only — needs network and,
// for the ssh leg, a reachable host with key auth already working.

if let i = CommandLine.arguments.firstIndex(of: "--audio"),
   i + 1 < CommandLine.arguments.count {
    let code = await IntegrationRunner.run(audioDir: CommandLine.arguments[i + 1])
    exit(Int32(code))
}

if let i = CommandLine.arguments.firstIndex(of: "--remote"),
   i + 1 < CommandLine.arguments.count {
    let target = i + 2 < CommandLine.arguments.count && !CommandLine.arguments[i + 2].hasPrefix("--")
        ? CommandLine.arguments[i + 2] : nil
    let code = await IntegrationRunner.runRemote(httpsURL: CommandLine.arguments[i + 1], sshTarget: target)
    exit(Int32(code))
}

// `swift run MMPTests --tags <file>...` prints the tags + embedded art each
// file yields through the real reader (FLAC/Ogg go via the native parsers).
if let i = CommandLine.arguments.firstIndex(of: "--tags"), i + 1 < CommandLine.arguments.count {
    let code = await IntegrationRunner.runTags(files: Array(CommandLine.arguments[(i + 1)...]))
    exit(Int32(code))
}

// `swift run MMPTests --cover <audio-file>` imports the file's tags, plays it,
// reports any embedded artwork, then hits the live iTunes Search API to fetch
// and apply a cover. Local only — needs network and an audio device.
if let i = CommandLine.arguments.firstIndex(of: "--cover"),
   i + 1 < CommandLine.arguments.count {
    let code = await IntegrationRunner.runCover(audioFile: CommandLine.arguments[i + 1])
    exit(Int32(code))
}

ScaffoldTests.register()
ModelCodingTests.register()
PlaylistNameTests.register()
ResumeTests.register()
LibraryStoreTests.register()
PlayerLogicTests.register()
RemoteLoaderTests.register()
MetadataCoverTests.register()
EngineLibraryTests.register()
ScanTests.register()
RuntimeDirTests.register()

await Harness.run()
