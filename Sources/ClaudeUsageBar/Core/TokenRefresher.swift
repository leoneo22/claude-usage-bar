import Foundation

/// Handles stale-token recovery by triggering Claude Code's built-in OAuth refresh.
///
/// Strategy: Spawn `claude` CLI with a trivial prompt — this forces its internal
/// token-refresh flow, which writes fresh credentials to the Keychain.
/// Fallback: If the CLI isn't installed, wait briefly and re-read Keychain.
enum TokenRefresher {
    private static let cliTimeout: TimeInterval = 15
    private static let passiveWait: TimeInterval = 3

    /// Cached path to the claude binary so we only search once per app session.
    /// Accessed only from DispatchQueue.global in findClaudeBinary — safe in practice.
    nonisolated(unsafe) private static var _cachedBinaryPath: String?
    nonisolated(unsafe) private static var _didSearchForBinary = false

    /// Called after a 401 response.
    /// - Returns: Fresh `OAuthCredentials` if the refresh succeeded, `nil` otherwise.
    static func waitForTokenRefresh() async throws -> OAuthCredentials? {
        let foundCLI: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                if let path = findClaudeBinary() {
                    NSLog("[ClaudeUsageBar] Refreshing token via CLI at: %@", path)
                    runCLI(at: path)
                    continuation.resume(returning: true)
                } else {
                    NSLog("[ClaudeUsageBar] Claude CLI not found — passive wait for token refresh")
                    continuation.resume(returning: false)
                }
            }
        }

        if !foundCLI {
            // Wait a bit in case another process (e.g. Claude Code in Terminal) refreshes
            try? await Task.sleep(for: .seconds(passiveWait))
        }

        // Re-read credentials — they may have been refreshed by CLI or another process.
        // Use allowUI: false so we never pop a password dialog from a background refresh.
        let creds = try KeychainManager.readClaudeCredentials(allowUI: false)
        return creds.isExpired ? nil : creds
    }

    // MARK: - CLI execution (called on background thread)

    private static func runCLI(at path: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["-p", ".", "--model", "claude-haiku-4-5-20251001", "--max-tokens", "1"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        // Inherit a usable PATH so the CLI can find node, etc.
        // GUI apps launched from Finder don't get the user's shell PATH.
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        var extraPaths = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin"
        ]
        // Resolve actual nvm node path if present (glob won't expand in env vars)
        if let nvmDir = try? FileManager.default.contentsOfDirectory(atPath: "\(home)/.nvm/versions/node") {
            if let latest = nvmDir.sorted().last {
                extraPaths.append("\(home)/.nvm/versions/node/\(latest)/bin")
            }
        }
        let currentPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")
        proc.environment = env

        guard (try? proc.run()) != nil else { return }

        let deadline = Date().addingTimeInterval(cliTimeout)
        while proc.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
        }
        if proc.isRunning { proc.terminate() }
    }

    // MARK: - Binary lookup (called on background thread)

    private static func findClaudeBinary() -> String? {
        if _didSearchForBinary { return _cachedBinaryPath }

        let home = NSHomeDirectory()
        let paths = [
            "\(home)/.local/bin/claude",          // npm global (common)
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(home)/.claude/local/claude",
        ]
        for p in paths where FileManager.default.isExecutableFile(atPath: p) {
            NSLog("[ClaudeUsageBar] Found claude binary at: %@", p)
            _cachedBinaryPath = p
            _didSearchForBinary = true
            return p
        }

        // Fallback: ask a login shell (picks up nvm, volta, Homebrew, etc.)
        if let resolved = resolveViaShell("claude") {
            NSLog("[ClaudeUsageBar] Resolved claude via shell: %@", resolved)
            _cachedBinaryPath = resolved
            _didSearchForBinary = true
            return resolved
        }

        NSLog("[ClaudeUsageBar] Could not find claude binary anywhere")
        _didSearchForBinary = true
        return nil
    }

    /// Uses a login shell to resolve a binary, picking up the user's full PATH
    /// (nvm, volta, Homebrew, etc.).
    ///
    /// GUI apps launched from Finder/Login Items don't inherit terminal PATH,
    /// so we spawn a login shell to get the real environment.
    private static func resolveViaShell(_ name: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // Login shell (-l) to pick up PATH from .zprofile/.zshrc
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
