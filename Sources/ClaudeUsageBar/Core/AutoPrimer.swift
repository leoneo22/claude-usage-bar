import Foundation

/// Sends a tiny Haiku message shortly after the 5-hour window resets,
/// so the new window starts counting immediately rather than waiting
/// for the user's next organic usage.
///
/// Timing: fires 2 minutes after `resetsAt` (the window boundary).
/// The countdown shown in the UI tracks the actual reset time.
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

    // MARK: - Callbacks

    /// Called immediately after a successful primer send.
    var onPrimed: (() async -> Void)?
    /// Provides the current access token without hitting Keychain.
    var tokenProvider: (() throws -> String)?

    // MARK: - Private

    private let messagesURL = URL(string: "https://api.anthropic.com/v1/messages")!
    /// How long after the window resets before we fire the primer.
    private let postResetDelay: TimeInterval = 120   // 2 minutes

    private var primeTask: Task<Void, Never>?
    /// The `resetsAt` date we're currently targeting. Used to avoid rescheduling
    /// on every poll when the target hasn't changed.
    private var targetResetDate: Date?

    // MARK: - Public API

    /// Called by OAuthUsageProvider after each successful poll.
    /// Schedules (or updates) the primer to fire shortly after the window resets.
    func handleUpdate(_ window: UsageWindow) {
        guard isEnabled else { return }
        guard let resetsAt = window.resetsAt else { return }

        // If we're already targeting this exact reset, nothing to do
        if let target = targetResetDate, abs(target.timeIntervalSince(resetsAt)) < 30 {
            return
        }

        // Schedule for resetsAt + postResetDelay
        let fireAt = resetsAt.addingTimeInterval(postResetDelay)

        // Don't schedule if the fire time is in the past (window already reset, we missed it)
        guard fireAt > Date() else { return }

        schedulePriming(fireAt: fireAt, resetsAt: resetsAt)
    }

    // MARK: - Scheduling

    private func schedulePriming(fireAt: Date, resetsAt: Date) {
        cancelScheduled()
        targetResetDate = resetsAt
        nextPrimeDate = fireAt

        let delay = fireAt.timeIntervalSinceNow
        NSLog("[ClaudeUsageBar] AutoPrimer: scheduled to fire in %.0f minutes (window resets at %@)",
              delay / 60, resetsAt.description)

        primeTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, self.isEnabled else { return }
            await self.fire()
        }
    }

    private func cancelScheduled() {
        primeTask?.cancel()
        primeTask = nil
        nextPrimeDate = nil
        targetResetDate = nil
    }

    // MARK: - Fire

    private func fire() async {
        // Try to get a token — if expired, attempt a direct OAuth refresh
        var token: String?
        token = try? tokenProvider?()
        if token == nil {
            NSLog("[ClaudeUsageBar] AutoPrimer: token expired, attempting refresh before priming")
            if let fresh = try? await TokenRefresher.refreshToken() {
                token = fresh.accessToken
            }
        }

        guard let token else {
            NSLog("[ClaudeUsageBar] AutoPrimer: no valid token available — skipping prime")
            cleanup()
            return
        }

        do {
            try await sendPrimeMessage(using: token)
            lastPrimed = Date()
            NSLog("[ClaudeUsageBar] AutoPrimer: successfully primed new window")
            cleanup()
            await onPrimed?()
        } catch {
            NSLog("[ClaudeUsageBar] AutoPrimer: prime failed — %@", error.localizedDescription)
            cleanup()
        }
    }

    private func cleanup() {
        primeTask = nil
        nextPrimeDate = nil
        targetResetDate = nil
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

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard http.statusCode == 200 else {
            NSLog("[ClaudeUsageBar] AutoPrimer: API returned HTTP %d", http.statusCode)
            throw URLError(.badServerResponse)
        }
    }
}
