import AppKit

// MARK: - Polling intervals (seconds)

private enum Interval {
    static let normal:         Double = 60
    static let afterError:     Double = 30
    static let backoff:        Double = 300   // 5 min — after 3 consecutive errors
    static let rateLimited1st: Double = 30    // 30 sec — first 429 (usually transient after wake)
    static let rateLimited:    Double = 120   // 2 min — subsequent 429s
    static let keychainDenied: Double = 600   // 10 min — don't spam password dialogs
    static let afterWake:      Double = 5     // let network stack reconnect
}

// MARK: - UsagePoller

/// Manages timer-based polling with exponential-style backoff and sleep/wake detection.
///
/// Owns the timing logic only. Actual fetch is delegated via `onPoll`.
@MainActor
final class UsagePoller {

    // MARK: - Callbacks

    /// Called every time a poll should occur. `onPoll` should set `lastPollError`.
    var onPoll: (() async -> Void)?
    /// Set by the provider after each poll so the poller knows whether to back off.
    var lastPollError: UsageError?

    // MARK: - State

    private var pollingTask: Task<Void, Never>?
    private var consecutiveErrors = 0
    private var wakeObserver: (any NSObjectProtocol)?

    // MARK: - Public API

    func start() {
        stop()
        setupWakeObserver()
        scheduleLoop()
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wakeObserver = nil
        }
    }

    /// Cancels current sleep and fires a poll immediately.
    func pollImmediately() {
        pollingTask?.cancel()
        scheduleLoop(delay: 0)
    }

    // MARK: - Loop

    private func scheduleLoop(delay: Double? = nil) {
        pollingTask = Task { [weak self] in
            guard let self else { return }

            // Optional initial delay (e.g. after rate-limit or backoff)
            if let delay, delay > 0 {
                do { try await Task.sleep(for: .seconds(delay)) }
                catch { return }
            }

            while !Task.isCancelled {
                await self.onPoll?()
                self.updateErrorCount()
                let interval = self.nextInterval()
                do { try await Task.sleep(for: .seconds(interval)) }
                catch { return }
            }
        }
    }

    private func updateErrorCount() {
        if lastPollError != nil {
            consecutiveErrors += 1
        } else {
            consecutiveErrors = 0
        }
    }

    private func nextInterval() -> Double {
        switch lastPollError {
        case .rateLimited(let retryAfter):
            // If the API told us exactly when to retry, respect it (capped at 10 min).
            if let seconds = retryAfter, seconds > 0 {
                return min(seconds, 600)
            }
            // No Retry-After header: first 429 retry quickly, then escalate.
            return consecutiveErrors <= 1 ? Interval.rateLimited1st : Interval.rateLimited
        case .keychainDenied:
            // User denied Keychain access — don't keep spamming password dialogs.
            // Wait 10 min, or until the user manually triggers "Poll Now".
            return Interval.keychainDenied
        case .some:
            return consecutiveErrors >= 3 ? Interval.backoff : Interval.afterError
        case .none:
            return Interval.normal
        }
    }

    // MARK: - Sleep/wake

    /// Polls after wake with a brief delay to let Wi-Fi/DNS reconnect.
    func pollAfterWake() {
        pollingTask?.cancel()
        scheduleLoop(delay: Interval.afterWake)
    }

    private func setupWakeObserver() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                NSLog("[ClaudeUsageBar] Wake detected — polling in %.0f seconds", Interval.afterWake)
                self?.pollAfterWake()
            }
        }
    }
}
