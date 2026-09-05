import Foundation
@testable import MacMusicPluginKit

enum ResumeTests {
    static func register() {
        Harness.test("ResumeState uses the C field names") {
            let state = ResumeState(playlist: "home", trackIndex: 3, positionMs: 45000, isPlaying: true)
            let data = try JSONEncoder().encode(state)
            let text = String(decoding: data, as: UTF8.self)
            Harness.expect(text.contains("\"track_index\":3"), "track_index")
            Harness.expect(text.contains("\"position_ms\":45000"), "position_ms")
            Harness.expect(text.contains("\"is_playing\":true"), "is_playing")
        }

        Harness.test("ResumeStore round-trips and clears") {
            let (dir, cleanup) = Harness.tempDir("resume")
            defer { cleanup() }
            let url = dir.appendingPathComponent(".resume.json")
            let store = ResumeStore(url: url, minWriteInterval: 0)

            store.write(ResumeState(playlist: "road", trackIndex: 7, positionMs: 1000, isPlaying: false),
                        force: true)
            let read = store.read()
            Harness.expectEqual(read?.playlist, "road")
            Harness.expectEqual(read?.trackIndex, 7)

            store.write(nil)
            Harness.expect(store.read() == nil, "nil clears the file")
        }

        Harness.test("ResumeStore parses a C-written file") {
            let (dir, cleanup) = Harness.tempDir("resume-c")
            defer { cleanup() }
            let url = dir.appendingPathComponent(".resume.json")
            let cText = "{\"playlist\":\"home\",\"track_index\":2,\"position_ms\":88000,\"is_playing\":true}\n"
            try Data(cText.utf8).write(to: url)
            let read = ResumeStore(url: url).read()
            Harness.expectEqual(read?.trackIndex, 2)
            Harness.expectEqual(read?.positionMs, 88000)
        }
    }
}
