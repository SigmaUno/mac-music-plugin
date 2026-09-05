import Foundation

// XCTest is unavailable under the Command Line Tools, so the suite is a plain
// executable. Each *Tests type registers its cases, then Harness.run() prints a
// summary and exits non-zero on failure.

ScaffoldTests.register()
ModelCodingTests.register()
PlaylistNameTests.register()
ResumeTests.register()
LibraryStoreTests.register()

Harness.run()
