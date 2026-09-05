import Foundation

/// Minimal test harness. XCTest is not available under the Command Line Tools,
/// so the suite is a plain executable: register cases with `test(_:)`, assert
/// with `expect`/`expectEqual`, and `Harness.run()` prints a summary and exits
/// non-zero on any failure (for CI).
enum Harness {
    struct Failure: Error { let message: String }

    private(set) static var cases: [(name: String, body: () async throws -> Void)] = []
    nonisolated(unsafe) static var currentFailures: [String] = []

    static func test(_ name: String, _ body: @escaping () throws -> Void) {
        cases.append((name, { try body() }))
    }

    /// An async case. Bodies that touch `@MainActor` types (e.g. `PlayerEngine`)
    /// declare themselves `@MainActor`; `run()` awaits the hop.
    static func testAsync(_ name: String, _ body: @escaping @MainActor @Sendable () async throws -> Void) {
        cases.append((name, { try await body() }))
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String,
                       file: StaticString = #file, line: UInt = #line) {
        if !condition() {
            currentFailures.append("\(message) (\(file):\(line))")
        }
    }

    static func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "",
                                          file: StaticString = #file, line: UInt = #line) {
        if a != b {
            let detail = message.isEmpty ? "" : "\(message): "
            currentFailures.append("\(detail)\(a) != \(b) (\(file):\(line))")
        }
    }

    static func run() async -> Never {
        var passed = 0
        var failed = 0
        for c in cases {
            currentFailures = []
            do {
                try await c.body()
            } catch {
                currentFailures.append("threw: \(error)")
            }
            if currentFailures.isEmpty {
                passed += 1
                print("  ok   \(c.name)")
            } else {
                failed += 1
                print("  FAIL \(c.name)")
                for f in currentFailures { print("       - \(f)") }
            }
        }
        print("\n\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    /// A scratch directory unique to the caller, auto-removed via the returned closure.
    static func tempDir(_ label: String = "t") -> (url: URL, cleanup: () -> Void) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mmp-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (url, { try? FileManager.default.removeItem(at: url) })
    }
}
