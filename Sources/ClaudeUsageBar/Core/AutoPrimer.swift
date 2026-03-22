import Foundation

/// Sends a tiny Haiku message shortly after detecting a 5-hour window reset,
/// so the new window starts counting immediately rather than waiting
/// for the user's next organic usage.
///
/// Detection: compares `resetsAt` across polls — when it jumps forward,
/// a reset just happened. Fires within seconds.
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

    /// Set to true when the system wakes from sleep.
    /// Causes the next primer to fire with minimal delay.
    private(set) var isPostWake: Bool = false

    // MARK: - Public API

    /// Called when the system wakes from sleep. Primes with minimal delay.
    func notifyWake() {
        isPostWake = true
        NSLog("[ClaudeUsageBar] AutoPrimer: wake detected — will use fast priming if reset found")
    }

    /// Called by OAuthUsageProvider after each successful poll.
    /// Detects when a window reset occurred and schedules a primer.
    func handleUpdate(_ window: UsageWindow) {
        guard let resetsAt = window.resetsAt else { return }

        defer {
            lastKnownResetsAt = resetsAt
            isPostWake = false  // consumed
        }

        guard isEnabled else { return }
        guard primeTask == nil else { return }

        let shouldPrime: Bool
        if let last = lastKnownResetsAt {
            // A real reset moves resetsAt forward by ~5 hours.
            // Small shifts (< 1 hour) are just the API adjusting — NOT a reset.
            let jump = resetsAt.timeIntervalSince(last)
            shouldPrime = jump > 3600
            if shouldPrime {
                NSLog("[ClaudeUsageBar] AutoPrimer: resetsAt jumped %.0f seconds forward — reset detected", jump)
            }
        } else {
            // First poll after launch: prime if window looks idle
            shouldPrime = window.utilization < idleThreshold
            if shouldPrime {
                NSLog("[ClaudeUsageBar] AutoPrimer: first poll, utilization %.1f%% < threshold — will prime", window.utilization)
            }
        }

        guard shouldPrime else { return }

        // If we just woke from sleep, network is confirmed up (we just polled) → fire fast
        let delay = isPostWake ? wakeDelay : normalDelay
        let fireAt = Date().addingTimeInterval(delay)
        schedulePriming(fireAt: fireAt)
        NSLog("[ClaudeUsageBar] AutoPrimer: priming in %.0f seconds (wake=%@)", delay, isPostWake ? "yes" : "no")
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
            guard !Task.isCancelled, self.isEnabled else { return }
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
        primeTask = Task { [weak self] in
            guard let self else { return }
            await self.fire()
        }
    }

    private func fire() async {
        // Try to get a token — if expired, attempt a direct OAuth refresh
        var token: String?
        token = try? tokenProvider?()
        if token == nil {
            NSLog("[ClaudeUsageBar] AutoPrimer: token expired, attempting refresh before priming")
            lastResult = "Refreshing token…"
            if let fresh = try? await TokenRefresher.refreshToken() {
                token = fresh.accessToken
            }
        }

        guard let token else {
            NSLog("[ClaudeUsageBar] AutoPrimer: no valid token available — skipping prime")
            lastResult = "❌ No valid token"
            cleanup()
            return
        }

        do {
            try await sendPrimeMessage(using: token)
            lastPrimed = Date()
            lastResult = "✅ Primed at \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short))"
            NSLog("[ClaudeUsageBar] AutoPrimer: successfully primed new window")
            cleanup()
            await onPrimed?()
        } catch {
            lastResult = "❌ \(error.localizedDescription)"
            NSLog("[ClaudeUsageBar] AutoPrimer: prime failed — %@", error.localizedDescription)
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
