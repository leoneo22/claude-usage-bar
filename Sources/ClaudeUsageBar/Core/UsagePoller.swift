import AppKit

// MARK: - Polling intervals (seconds)

private enum Interval {
    static let normal:         Double = 180    // 3 min — usage doesn't change faster than this
    static let afterError:     Double = 60     // 1 min — general error retry
    static let backoff:        Double = 300    // 5 min — after 3 consecutive errors
    static let keychainDenied: Double = 600    // 10 min — don't spam password dialogs
    static let afterWake:      Double = 5      // let network stack reconnect

    /// Exponential backoff for 429s: 2 min → 4 min → 8 min → 10 min cap.
    /// The usage API has strict rate limits; hammering it keeps us locked out.
    static func rateLimitBackoff(consecutiveErrors: Int) -> Double {
        let base: Double = 120  // start at 2 min
        let multiplier = pow(2.0, Double(max(0, consecutiveErrors - 1)))
        return min(base * multiplier, 600)  // cap at 10 min
    }
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
    /// Called when the system wakes from sleep, before polling.
    var onWake: (() -> Void)?
    /// Set by the provider after each poll so the poller knows whether to back off.
    var lastPollError: UsageError?

    // MARK: - State

    private var pollingTask: Task<Void, Never>?
    private(set) var consecutiveErrors = 0
    private var wakeObserver: (any NSObjectProtocol)?

    /// The next time a poll will fire — exposed so the UI can show "retrying in ~X min".
    private(set) var nextPollDate: Date?

    // MARK: - Public API

    func start() {
        stop()
        setupWakeObserver()
        scheduleLoop()
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        nextPollDate = nil
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wakeObserver = nil
        }
    }

    /// Cancels current sleep and fires a poll immediately.
    func pollImmediately() {
        consecutiveErrors = 0   // user asked — reset backoff
        pollingTask?.cancel()
        scheduleLoop(delay: 0)
    }

    // MARK: - Loop

    private func scheduleLoop(delay: Double? = nil) {
        pollingTask = Task { [weak self] in
            guard let self else { return }

            // Optional initial delay (e.g. after rate-limit or backoff)
            if let delay, delay > 0 {
                self.nextPollDate = Date().addingTimeInterval(delay)
                do { try await Task.sleep(for: .seconds(delay)) }
                catch { return }
            }

            while !Task.isCancelled {
                self.nextPollDate = nil
                await self.onPoll?()
                self.updateErrorCount()
                let interval = self.nextInterval()
                self.nextPollDate = Date().addingTimeInterval(interval)
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
            // If the API told us exactly when to retry AND it's > 0, respect it (capped at 10 min).
            if let seconds = retryAfter, seconds > 0 {
                return min(seconds, 600)
            }
            // retry-after: 0 or missing → exponential backoff: 2m, 4m, 8m, 10m cap
            return Interval.rateLimitBackoff(consecutiveErrors: consecutiveErrors)
        case .keychainDenied:
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
        onWake?()  // Notify listeners (e.g. AutoPrimer) before polling
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
