import Foundation

/// Abstraction over data sources so API-key support can be added later
/// without touching any existing code.
@MainActor
protocol UsageProvider: ObservableObject {
    var fiveHour: UsageWindow? { get }
    var sevenDay: UsageWindow? { get }
    var lastUpdated: Date? { get }
    var error: UsageError? { get }

    /// Fetch fresh data once.
    func poll() async
    /// Start periodic polling.
    func startPolling()
    /// Stop periodic polling.
    func stopPolling()
}
