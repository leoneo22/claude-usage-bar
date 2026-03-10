import Foundation

/// Handles stale-token recovery by triggering Claude Code's built-in OAuth refresh.
///
/// Strategy: Spawn `claude` CLI with a trivial prompt — this forces its internal
/// token-refresh flow, which writes fresh credentials to the Keychain.
/// Fallback: If the CLI isn't installed, wait briefly and re-read Keychain.
enum TokenRefresher {
    private static let cliTimeout: TimeInterval = 15
    private static let passiveWait: TimeInterval = 3

    /// Called after a 401 response.
    /// - Returns: Fresh `OAuthCredentials` if the refresh succeeded, `nil` otherwise.
    static func waitForTokenRefresh() async throws -> OAuthCredentials? {
        let foundCLI: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                if let path = findClaudeBinary() {
                    runCLI(at: path)
                    continuation.resume(returning: true)
                } else {
                    continuation.resume(returning: false)
                }
            }
        }

        if !foundCLI {
            try? await Task.sleep(for: .seconds(passiveWait))
        }

        let creds = try KeychainManager.readClaudeCredentials()
        return creds.isExpired ? nil : creds
    }

    // MARK: - CLI execution (called on background thread)

    private static func runCLI(at path: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["-p", ".", "--model", "claude-haiku-4-5-20251001", "--max-tokens", "1"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        guard (try? proc.run()) != nil else { return }

        let deadline = Date().addingTimeInterval(cliTimeout)
        while proc.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
        }
        if proc.isRunning { proc.terminate() }
    }

    // MARK: - Binary lookup (called on background thread)

    private static func findClaudeBinary() -> String? {
        let paths = [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            NSHomeDirectory() + "/.claude/local/claude"
        ]
        for p in paths where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return resolveViaShell("claude")
    }

    /// Uses a login shell to resolve a binary, picking up the user's full PATH
    /// (nvm, volta, Homebrew, etc.).
    private static func resolveViaShell(_ name: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-l", "-c", "which \(name)"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }
}
