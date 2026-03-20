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

    /// Cached token to avoid hitting Keychain every poll cycle.
    /// Re-read only on startup, expiry, or 401.
    private var cachedToken: String?
    private var cachedTokenExpiry: Date?

    /// Exposed so the popup view can observe and toggle primer state.
    let autoPrimer = AutoPrimer()

    // MARK: - Init

    init() {
        poller.onPoll = { [weak self] in await self?.poll() }
        autoPrimer.onPrimed = { [weak self] in self?.pollNow() }
        autoPrimer.tokenProvider = { [weak self] in
            guard let self else { throw UsageError.authExpired }
            return try self.getToken()
        }
    }

    // MARK: - UsageProvider conformance

    /// Maximum number of token-refresh retries before giving up on a single poll cycle.
    private static let maxRefreshRetries = 2

    func poll() async {
        do {
            let token = try getToken()
            let response = try await fetchUsage(using: token)
            applyResponse(response)
            poller.lastPollError = nil
        } catch UsageError.authExpired {
            // 401 or expired token: invalidate cache and attempt refresh
            await handleAuthExpired()
        } catch let e as KeychainError where e.isAccessDenied {
            // User denied Keychain access or it's locked — do NOT retry automatically.
            // Retrying would immediately pop another password dialog.
            NSLog("[ClaudeUsageBar] Keychain access denied — backing off to avoid repeated prompts")
            setError(.keychainDenied)
        } catch let e as KeychainError {
            // Other Keychain errors (not found, bad data) — try refresh flow
            NSLog("[ClaudeUsageBar] Keychain error: %@", e.localizedDescription)
            await handleAuthExpired()
        } catch let e as UsageError {
            setError(e)
        } catch {
            setError(.networkError(error.localizedDescription))
        }
    }

    /// Shared auth-recovery flow: invalidate cache, run CLI refresh, retry.
    private func handleAuthExpired() async {
        invalidateTokenCache()

        for attempt in 1...Self.maxRefreshRetries {
            NSLog("[ClaudeUsageBar] Token refresh attempt %d/%d", attempt, Self.maxRefreshRetries)

            do {
                guard let fresh = try await TokenRefresher.waitForTokenRefresh() else {
                    // CLI ran but token is still expired
                    if attempt < Self.maxRefreshRetries {
                        try? await Task.sleep(for: .seconds(2))
                    }
                    continue
                }
                cachedToken = fresh.accessToken
                cachedTokenExpiry = fresh.expiresAt
                let response = try await fetchUsage(using: fresh.accessToken)
                applyResponse(response)
                poller.lastPollError = nil
                NSLog("[ClaudeUsageBar] Token refresh succeeded on attempt %d", attempt)
                return
            } catch let e as KeychainError where e.isAccessDenied {
                // Keychain prompted and user denied — stop immediately, don't re-prompt
                NSLog("[ClaudeUsageBar] Keychain denied during refresh — aborting retries")
                setError(.keychainDenied)
                return
            } catch UsageError.authExpired {
                // Token was refreshed but API still rejected — try again
                invalidateTokenCache()
                if attempt < Self.maxRefreshRetries {
                    try? await Task.sleep(for: .seconds(2))
                }
                continue
            } catch let e as UsageError {
                setError(e); return
            } catch {
                setError(.networkError(error.localizedDescription)); return
            }
        }

        setError(.authExpired)
    }

    func startPolling() {
        poller.start()
    }

    func stopPolling() {
        poller.stop()
    }

    /// Cancels the current sleep and polls immediately (e.g. "Poll Now" menu item).
    /// This is user-triggered, so we allow Keychain UI prompts (one-time password dialog).
    func pollNow() {
        // If we're in a keychainDenied state, try a UI-allowed read first.
        // This is the only code path that shows a Keychain password dialog.
        if case .keychainDenied = error {
            do {
                let creds = try KeychainManager.readClaudeCredentials(allowUI: true)
                if !creds.isExpired {
                    cachedToken = creds.accessToken
                    cachedTokenExpiry = creds.expiresAt
                    error = nil
                }
            } catch {
                // User denied again or other error — the poll will handle it
            }
        }
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

    // MARK: - Token cache

    /// Returns a cached token or reads a fresh one from Keychain.
    /// Only touches Keychain on first call, after expiry, or after invalidation.
    /// Uses silent Keychain reads (no password dialog) for background polls.
    private func getToken() throws -> String {
        if let token = cachedToken,
           let expiry = cachedTokenExpiry,
           expiry > Date() {
            return token
        }
        // allowUI: false → fail silently instead of showing a macOS password dialog.
        // If the user hasn't granted "Always Allow", this will throw .accessDenied
        // without interrupting the user. They can use "Poll Now" to trigger a read
        // with UI allowed.
        let creds = try KeychainManager.readClaudeCredentials(allowUI: false)
        // If the Keychain token is already expired, throw immediately
        // so the caller can trigger the refresh flow instead of making
        // a doomed API call that returns 401.
        guard !creds.isExpired else {
            throw UsageError.authExpired
        }
        cachedToken = creds.accessToken
        cachedTokenExpiry = creds.expiresAt
        return creds.accessToken
    }

    private func invalidateTokenCache() {
        cachedToken = nil
        cachedTokenExpiry = nil
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
