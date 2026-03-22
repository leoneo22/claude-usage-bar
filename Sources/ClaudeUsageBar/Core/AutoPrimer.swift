import Foundation

/// Sends a tiny Haiku message shortly after detecting a 5-hour window reset,
/// so the new window starts counting immediately rather than waiting
/// for the user's next organic usage.
///
/// Detection uses TWO methods:
///   1. Jump detection: `resetsAt` moves forward by >1 hour = new window.
///   2. Idle detection: utilization < 2% and we haven't primed yet.
///
/// The idle detection is the safety net — it catches cases where the jump
/// was missed (app restart, `resetsAt` was nil, timing edge cases).
///
/// Cost: ~3 tokens per fire — negligible.
@MainActor
final class AutoPrimer: ObservableObject {

    // MARK: - Published state

    @Published var isEnabled: Bool = true {
        didSet { if !isEnabled { cancelScheduled() } }
    }
    @Published private(set) var nextPrimeDate: Date?
    @Published private(set) var lastPrimed: Date?
    @Published private(set) var lastResult: String?

    // MARK: - Callbacks

    /// Called immediately after a successful primer send.
    var onPrimed: (() async -> Void)?
    /// Provides the current access token without hitting Keychain.
    var tokenProvider: (() throws -> String)?

    // MARK: - Private

    private let messagesURL = URL(string: "https://api.anthropic.com/v1/messages")!
    /// Normal delay after detecting a reset — brief pause to let things settle.
    private let normalDelay: TimeInterval = 10       // 10 seconds
    /// Wake delay — network is already up (we just polled), fire fast.
    private let wakeDelay: TimeInterval = 2          // 2 seconds
    private let idleThreshold: Double = 2.0          // < 2% = considered idle

    private var primeTask: Task<Void, Never>?
    private var lastKnownResetsAt: Date?
    /// Prevents re-priming the same window. Reset when a new window is detected.
    private var hasPrimedThisWindow: Bool = false

    /// Set to true when the system wakes from sleep.
    /// Causes the next primer to fire with minimal delay.
    private(set) var isPostWake: Bool = false

    // MARK: - Diagnostics

    /// File-based log for debugging — NSLog doesn't reliably appear in macOS Console.
    private static let logPath = NSHomeDirectory() + "/.claude/primer-diagnostic.log"

    private static func log(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        NSLog("[ClaudeUsageBar] AutoPrimer: %@", message)
        if let fh = FileHandle(forWritingAtPath: logPath) {
            fh.seekToEndOfFile()
            fh.write(line.data(using: .utf8) ?? Data())
            fh.closeFile()
        } else {
            FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8))
        }
    }

    // MARK: - Public API

    /// Called when the system wakes from sleep. Primes with minimal delay.
    func notifyWake() {
        isPostWake = true
        Self.log("wake detected — will use fast priming if reset found")
    }

    /// Called by OAuthUsageProvider after each successful poll.
    /// Detects when a window reset occurred and schedules a primer.
    func handleUpdate(_ window: UsageWindow) {
        let resetsAt = window.resetsAt  // may be nil for fresh windows

        defer {
            if let resetsAt {
                lastKnownResetsAt = resetsAt
            }
            isPostWake = false  // consumed
        }

        Self.log("handleUpdate: util=\(String(format: "%.1f", window.utilization))% resetsAt=\(resetsAt?.description ?? "nil") lastKnown=\(lastKnownResetsAt?.description ?? "nil") hasPrimed=\(hasPrimedThisWindow) taskActive=\(primeTask != nil)")

        guard isEnabled else {
            Self.log("  → skipped: disabled")
            return
        }
        guard primeTask == nil else {
            Self.log("  → skipped: task already active")
            return
        }

        // Detect window reset: resetsAt jumped forward by more than 1 hour
        let isNewWindow: Bool
        if let resetsAt, let last = lastKnownResetsAt {
            let jump = resetsAt.timeIntervalSince(last)
            isNewWindow = jump > 3600
            if isNewWindow {
                Self.log("  → NEW WINDOW detected: resetsAt jumped \(Int(jump))s forward")
            }
        } else {
            isNewWindow = false
        }

        // Reset the "already primed" flag when a new window is detected
        if isNewWindow {
            hasPrimedThisWindow = false
        }

        // If we already primed this window, don't prime again
        guard !hasPrimedThisWindow else {
            Self.log("  → skipped: already primed this window")
            return
        }

        // Should we prime?
        //  1. We just detected a new window via jump
        //  2. Window is idle (utilization < 2%) — catches missed jumps, nil resetsAt, app restarts
        let shouldPrime = isNewWindow || window.utilization < idleThreshold

        if !shouldPrime {
            Self.log("  → skipped: not new window and utilization \(String(format: "%.1f", window.utilization))% >= threshold")
            return
        }

        let reason = isNewWindow ? "new window (jump)" : "idle window (util \(String(format: "%.1f", window.utilization))%)"
        let delay = isPostWake ? wakeDelay : normalDelay
        let fireAt = Date().addingTimeInterval(delay)
        Self.log("  → PRIMING in \(Int(delay))s — reason: \(reason), wake=\(isPostWake)")
        schedulePriming(fireAt: fireAt)
    }

    // MARK: - Scheduling

    private func schedulePriming(fireAt: Date) {
        cancelScheduled()
        nextPrimeDate = fireAt
        let delay = max(0, fireAt.timeIntervalSinceNow)

        primeTask = Task { [weak self] in
            guard let self else { return }
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled, self.isEnabled else {
                Self.log("fire cancelled before execution")
                return
            }
            await self.fire()
        }
    }

    private func cancelScheduled() {
        primeTask?.cancel()
        primeTask = nil
        nextPrimeDate = nil
    }

    // MARK: - Fire

    /// Manually trigger a primer fire (for testing / "Prime Now" menu item).
    func primeNow() {
        cancelScheduled()
        lastResult = "Firing…"
        Self.log("primeNow() called — manual trigger")
        primeTask = Task { [weak self] in
            guard let self else { return }
            await self.fire()
        }
    }

    private func fire() async {
        Self.log("fire() starting — getting token")
        // Try to get a token — if expired, attempt a direct OAuth refresh
        var token: String?
        token = try? tokenProvider?()
        if token == nil {
            Self.log("fire() token expired, attempting refresh")
            lastResult = "Refreshing token…"
            if let fresh = try? await TokenRefresher.refreshToken() {
                token = fresh.accessToken
                Self.log("fire() token refreshed successfully")
            }
        }

        guard let token else {
            Self.log("fire() FAILED — no valid token")
            lastResult = "❌ No valid token"
            cleanup()
            return
        }

        do {
            try await sendPrimeMessage(using: token)
            hasPrimedThisWindow = true
            lastPrimed = Date()
            lastResult = "✅ Primed at \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short))"
            Self.log("fire() SUCCESS — primed at \(Date())")
            cleanup()
            await onPrimed?()
        } catch {
            lastResult = "❌ \(error.localizedDescription)"
            Self.log("fire() FAILED — \(error.localizedDescription)")
            cleanup()
        }
    }

    private func cleanup() {
        primeTask = nil
        nextPrimeDate = nil
    }

    // MARK: - Network

    private func sendPrimeMessage(using accessToken: String) async throws {
        var request = URLRequest(url: messagesURL)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01",            forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20",      forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json",       forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model":      "claude-haiku-4-5-20251001",
            "max_tokens": 1,
            "messages":   [["role": "user", "content": "hi"]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Use ephemeral session to avoid caching issues
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard http.statusCode == 200 else {
            let responseBody = String(data: data, encoding: .utf8) ?? "(no body)"
            Self.log("API returned HTTP \(http.statusCode): \(responseBody)")
            throw URLError(.badServerResponse)
        }
    }
}
