import Foundation
@testable import MacMusicPluginKit

// Milestone 1 — scaffold sanity.
Harness.test("Paths point under Application Support") {
    Harness.expect(Paths.support.path.contains("Application Support/MacMusicPlugin"),
                   "support dir is under Application Support")
    Harness.expectEqual(Paths.library.lastPathComponent, "library")
    Harness.expectEqual(Paths.resumeFile.lastPathComponent, ".resume.json")
}

Harness.run()
