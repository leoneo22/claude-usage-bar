import Foundation

/// Sends a tiny Haiku message 55 minutes after a 5-hour window resets (if idle),
/// so the new window starts counting early rather than waiting for organic usage.
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

    // MARK: - Callback

    /// Called immediately after a successful primer send.
    var onPrimed: (() async -> Void)?

    // MARK: - Private

    private let messagesURL = URL(string: "https://api.anthropic.com/v1/messages")!
    private let delay: TimeInterval = 55 * 60   // 55 minutes
    private let idleThreshold: Double = 2.0     // < 2% = considered idle

    private var primeTask: Task<Void, Never>?
    private var lastKnownResetsAt: Date?

    // MARK: - Public API

    /// Called by OAuthUsageProvider after each successful poll.
    /// Detects window resets and schedules a primer if the window was reset.
    func handleUpdate(_ window: UsageWindow) {
        guard let resetsAt = window.resetsAt else { return }

        defer { lastKnownResetsAt = resetsAt }

        guard isEnabled else { return }
        guard primeTask == nil else { return }

        if let last = lastKnownResetsAt {
            // Subsequent polls: detect reset (resetsAt moved to a later date)
            guard resetsAt > last else { return }
        } else {
            // First poll after launch: if window looks idle, prime it
            guard window.utilization < idleThreshold else { return }
        }

        schedulePriming()
    }

    // MARK: - Scheduling

    private func schedulePriming() {
        cancelScheduled()
        let fireAt = Date().addingTimeInterval(delay)
        nextPrimeDate = fireAt

        primeTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.delay))
            guard !Task.isCancelled, self.isEnabled else { return }
            await self.fireIfIdle()
        }
    }

    private func cancelScheduled() {
        primeTask?.cancel()
        primeTask = nil
        nextPrimeDate = nil
    }

    // MARK: - Fire

    private func fireIfIdle() async {
        // Re-read Keychain for fresh token (55 min have elapsed)
        guard let creds = try? KeychainManager.readClaudeCredentials(),
              !creds.isExpired else { return }

        do {
            try await sendPrimeMessage(using: creds.accessToken)
            lastPrimed = Date()
            nextPrimeDate = nil
            primeTask = nil
            await onPrimed?()
        } catch {
            // Primer failure is non-critical — reset state silently
            primeTask = nil
            nextPrimeDate = nil
        }
    }

    // MARK: - Network

    private func sendPrimeMessage(using accessToken: String) async throws {
        var request = URLRequest(url: messagesURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01",            forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json",       forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model":      "claude-haiku-4-5-20251001",
            "max_tokens": 1,
            "messages":   [["role": "user", "content": "hi"]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }
}
