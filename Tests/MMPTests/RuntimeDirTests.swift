import Foundation
@testable import MacMusicPluginKit

enum RuntimeDirTests {
    static func register() {
        Harness.test("RuntimeDir is a short, private /tmp path") {
            let base = RuntimeDir.base.path
            Harness.expect(base.hasPrefix("/tmp/mmp-") || base.hasPrefix("/private/tmp/mmp-"),
                           "under /tmp/mmp-<uid> (got \(base))")
            // The ssh control socket path must fit a sockaddr_un (~104 bytes):
            // <base>/ssh/cm-<64 hex> plus a NUL.
            Harness.expect(RuntimeDir.ssh.path.utf8.count + "/cm-".utf8.count + 64 < 104,
                           "control socket path fits sockaddr_un")
        }

        Harness.test("ControlMaster options engage for the real ssh control dir") {
            let opts = RemoteCommand.sshCat(username: "u", ip: "h", remotePath: "/m/a.flac",
                                            controlDirectory: Paths.sshControl) ?? []
            Harness.expect(opts.contains("ControlMaster=auto"), "multiplexing enabled by default")
            Harness.expect(opts.contains { $0.hasPrefix("ControlPath=") }, "ControlPath set")

            // A path too long for sockaddr_un falls back to un-multiplexed ssh.
            let longDir = URL(fileURLWithPath: "/Users/someone/Library/Application Support/MacMusicPlugin/ssh")
            let none = RemoteCommand.sshCat(username: "u", ip: "h", remotePath: "/m/a.flac",
                                            controlDirectory: longDir) ?? []
            Harness.expect(!none.contains("ControlMaster=auto"), "long path disables multiplexing")
        }
    }
}
