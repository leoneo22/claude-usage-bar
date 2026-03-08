import Foundation
import Combine

// MARK: - OAuthUsageProvider

/// Fetches Claude usage data using the OAuth access token stored by Claude Code.
@MainActor
final class OAuthUsageProvider: ObservableObject {

    // MARK: - Published state

    @Published private(set) var fiveHour: UsageWindow?
    @Published private(set) var sevenDay: UsageWindow?
    @Published private(set) var sevenDayOpus: UsageWindow?
    @Published private(set) var sevenDaySonnet: UsageWindow?
    @Published private(set) var sevenDayCowork: UsageWindow?
    @Published private(set) var extraUsage: ExtraUsage?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var error: UsageError?

    // MARK: - Private

    private let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let poller = UsagePoller()

    /// Exposed so the popup view can observe and toggle primer state.
    let autoPrimer = AutoPrimer()

    // MARK: - Init

    init() {
        poller.onPoll = { [weak self] in await self?.poll() }
        autoPrimer.onPrimed = { [weak self] in self?.pollNow() }
    }

    // MARK: - UsageProvider conformance

    func poll() async {
        do {
            let creds = try KeychainManager.readClaudeCredentials()
            let response = try await fetchUsage(using: creds.accessToken)
            applyResponse(response)
            poller.lastPollError = nil
        } catch UsageError.authExpired {
            // 401: give Claude Code a moment to refresh the token, then retry once
            if let fresh = try? await TokenRefresher.waitForTokenRefresh() {
                do {
                    let response = try await fetchUsage(using: fresh.accessToken)
                    applyResponse(response)
                    poller.lastPollError = nil
                    return
                } catch let e as UsageError {
                    setError(e); return
                } catch {
                    setError(.networkError(error.localizedDescription)); return
                }
            }
            setError(.authExpired)
        } catch let e as UsageError {
            setError(e)
        } catch let e as KeychainError {
            setError(.credentialError(e.localizedDescription))
        } catch {
            setError(.networkError(error.localizedDescription))
        }
    }

    func startPolling() {
        poller.start()
    }

    func stopPolling() {
        poller.stop()
    }

    /// Cancels the current sleep and polls immediately (e.g. "Poll Now" menu item).
    func pollNow() {
        poller.pollImmediately()
    }

    // MARK: - Helpers

    private func applyResponse(_ response: UsageResponse) {
        fiveHour = response.fiveHour
        sevenDay = response.sevenDay
        sevenDayOpus = response.sevenDayOpus
        sevenDaySonnet = response.sevenDaySonnet
        sevenDayCowork = response.sevenDayCowork
        extraUsage = response.extraUsage
        lastUpdated = Date()
        error = nil
        autoPrimer.handleUpdate(response.fiveHour)
    }

    private func setError(_ e: UsageError) {
        error = e
        poller.lastPollError = e
    }

    // MARK: - Network

    /// Token is passed in, used only within this call, then discarded.
    private func fetchUsage(using accessToken: String) async throws -> UsageResponse {
        var request = URLRequest(url: usageURL)
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20",      forHTTPHeaderField: "anthropic-beta")

        let (data, httpResponse) = try await URLSession.shared.data(for: request)

        guard let http = httpResponse as? HTTPURLResponse else {
            throw UsageError.networkError("Expected HTTP response")
        }

        switch http.statusCode {
        case 200:   break
        case 401:   throw UsageError.authExpired
        case 429:   throw UsageError.rateLimited
        default:    throw UsageError.httpError(http.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) { return d }
            iso.formatOptions = [.withInternetDateTime]
            if let d = iso.date(from: s) { return d }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad date: \(s)")
        }
        return try decoder.decode(UsageResponse.self, from: data)
    }
}
