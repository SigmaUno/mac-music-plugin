import Foundation

/// Unlocking the SSH agent for `ssh`/local-network sources whose key needs a
/// passphrase.
///
/// The Omarchy backend spawns its own `ssh-agent` and runs `ssh-add` against it
/// (`unlock_ssh_agent`, backend/app.c:808). On macOS the launchd-managed agent
/// is already there (`SSH_AUTH_SOCK` is set for every GUI process), so there is
/// no agent to start — only keys to add. A menu-bar `LSUIElement` app has no
/// terminal to prompt in, so this opens Terminal to run `ssh-add`, which is what
/// `NSAppleEventsUsageDescription` in Info.plist tells the user.
public enum SSHAgent {
    public enum UnlockResult: Equatable, Sendable {
        case openedTerminal
        case failed(String)
    }

    /// `ssh-add --apple-load-keychain` first (pulls in any passphrases the user
    /// saved to the login keychain), then a plain `ssh-add` so a not-in-keychain
    /// key still gets an interactive passphrase prompt in the Terminal window.
    static let script = """
    tell application "Terminal"
        activate
        do script "ssh-add --apple-load-keychain 2>/dev/null; ssh-add; echo; echo 'You can close this window.'"
    end tell
    """

    @discardableResult
    public static func unlock(runner: (String) -> Bool = SSHAgent.runAppleScript) -> UnlockResult {
        runner(script)
            ? .openedTerminal
            : .failed("Could not open Terminal to run ssh-add.")
    }

    public static func runAppleScript(_ source: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
