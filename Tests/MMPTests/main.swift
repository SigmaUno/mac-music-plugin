import Foundation

// XCTest is unavailable under the Command Line Tools, so the suite is a plain
// executable. Each *Tests type registers its cases, then Harness.run() prints a
// summary and exits non-zero on failure.
//
// `swift run MMPTests --audio <dir>` instead runs the real-audio integration
// check (local only — CI runners have no output device).

if let i = CommandLine.arguments.firstIndex(of: "--audio"),
   i + 1 < CommandLine.arguments.count {
    let code = await IntegrationRunner.run(audioDir: CommandLine.arguments[i + 1])
    exit(Int32(code))
}

ScaffoldTests.register()
ModelCodingTests.register()
PlaylistNameTests.register()
ResumeTests.register()
LibraryStoreTests.register()
PlayerLogicTests.register()

Harness.run()
