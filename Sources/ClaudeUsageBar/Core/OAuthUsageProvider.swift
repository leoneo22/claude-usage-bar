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

    /// Ephemeral session — zero caching at every level (disk, memory, system).
    /// Prevents macOS from caching 429 responses and serving stale errors.
    private let urlSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    /// Cached token to avoid hitting Keychain every poll cycle.
    /// Re-read only on startup, expiry, or 401.
    private var cachedToken: String?
    private var cachedTokenExpiry: Date?

    /// Exposed so the popup view can observe and toggle primer state.
    let autoPrimer = AutoPrimer()

    // MARK: - Init

    init() {
        // Purge any cached API responses (macOS can cache 429s and serve them forever)
        URLCache.shared.removeAllCachedResponses()

        poller.onPoll = { [weak self] in await self?.poll() }
        poller.onWake = { [weak self] in self?.autoPrimer.notifyWake() }
        autoPrimer.onPrimed = { [weak self] in self?.pollNow() }
        autoPrimer.tokenProvider = { [weak self] in
            guard let self else { throw UsageError.authExpired }
            return try self.getToken()
        }
    }

    // MARK: - Polling

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

    /// Refreshes the OAuth token directly via the Anthropic token endpoint,
    /// then retries the usage fetch once.
    private func handleAuthExpired() async {
        invalidateTokenCache()

        do {
            guard let fresh = try await TokenRefresher.refreshToken() else {
                // Refresh was skipped (rate-limited or too soon) — just set the error
                setError(.authExpired)
                return
            }
            cachedToken = fresh.accessToken
            cachedTokenExpiry = fresh.expiresAt

            // Token refreshed — try fetching usage with it
            let response = try await fetchUsage(using: fresh.accessToken)
            applyResponse(response)
            poller.lastPollError = nil
            NSLog("[ClaudeUsageBar] Token refresh + usage fetch succeeded")
        } catch let e as KeychainError where e.isAccessDenied {
            NSLog("[ClaudeUsageBar] Keychain denied during refresh")
            setError(.keychainDenied)
        } catch let e as UsageError where e.isRateLimited {
            // Usage API returned 429 but the token IS fresh — just wait
            NSLog("[ClaudeUsageBar] Usage API rate limited after token refresh")
            setError(e)
        } catch let e as UsageError {
            setError(e)
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
    /// This is user-triggered, so we allow Keychain UI prompts and reset backoffs.
    func pollNow() {
        // Reset refresh backoff — the user is explicitly asking to retry
        TokenRefresher.resetBackoff()

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

        // Export current tokens to iCloud Drive for the iOS phone-based primer
        exportTokensToiCloud()
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

    // MARK: - iCloud token export (for iOS phone-based primer)

    /// Exports the current access + refresh token to iCloud Drive so the iOS Shortcut
    /// can read them and fire primer messages overnight.
    ///
    /// File: ~/Library/Mobile Documents/com~apple~CloudDocs/ClaudePrimer/token.json
    /// Syncs automatically to the user's iPhone via iCloud Drive.
    private func exportTokensToiCloud() {
        guard let token = cachedToken, let expiry = cachedTokenExpiry else { return }

        // Read refresh token from Keychain for the export
        let refreshToken: String?
        do {
            let creds = try KeychainManager.readClaudeCredentials(allowUI: false)
            refreshToken = creds.refreshToken
        } catch {
            refreshToken = nil
        }

        let payload: [String: Any] = [
            "access_token": token,
            "refresh_token": refreshToken ?? "",
            "expires_at": expiry.timeIntervalSince1970,
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
            "updated_at": ISO8601DateFormatter().string(from: Date()),
        ]

        let fm = FileManager.default
        let iCloudDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/ClaudePrimer")

        do {
            try fm.createDirectory(at: iCloudDir, withIntermediateDirectories: true)
            let file = iCloudDir.appendingPathComponent("token.json")
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: file, options: .atomic)
        } catch {
            // Non-critical — don't log noise if iCloud Drive isn't set up
        }
    }

    /// Debug logging for API issues — writes to NSLog only (no disk file).
    private static func appendDebugLog(_ message: String) {
        NSLog("[ClaudeUsageBar] %@", message)
    }

    // MARK: - Network

    /// Token is passed in, used only within this call, then discarded.
    private func fetchUsage(using accessToken: String) async throws -> UsageResponse {
        var request = URLRequest(url: usageURL)
        request.timeoutInterval = 15
        // CRITICAL: Never use cached responses. macOS can cache 429 responses and serve
        // them indefinitely, causing the app to appear permanently rate-limited.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20",      forHTTPHeaderField: "anthropic-beta")

        let (data, httpResponse) = try await urlSession.data(for: request)

        guard let http = httpResponse as? HTTPURLResponse else {
            throw UsageError.networkError("Expected HTTP response")
        }

        switch http.statusCode {
        case 200:   break
        case 401:   throw UsageError.authExpired
        case 429:
            // Dump full 429 details to a debug file — NSLog doesn't reliably appear in macOS logs
            let body = String(data: data, encoding: .utf8) ?? "(no body)"
            let retryAfterStr = http.value(forHTTPHeaderField: "Retry-After") ?? "not set"
            let allHeaders = http.allHeaderFields.map { "\($0.key): \($0.value)" }.joined(separator: "\n  ")
            let debugInfo = """
            [\(Date())] 429 Rate Limited
            Retry-After: \(retryAfterStr)
            Headers:
              \(allHeaders)
            Body: \(body)
            ---
            """
            Self.appendDebugLog(debugInfo)
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            throw UsageError.rateLimited(retryAfter: retryAfter)
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
