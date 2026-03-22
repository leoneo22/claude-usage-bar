import Foundation

/// Handles stale-token recovery via the OAuth refresh_token flow.
///
/// Calls the Anthropic token endpoint directly — no CLI dependency.
/// Writes refreshed credentials back to Keychain so Claude Code stays in sync.
///
/// **Rate-limit discipline:** At most one refresh per `minRefreshInterval`.
/// If the endpoint returns 429, backs off for `rateLimitBackoff` before retrying.
enum TokenRefresher {

    // MARK: - Configuration

    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let clientID  = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    /// Minimum time between refresh attempts (prevents hammering the endpoint).
    private static let minRefreshInterval: TimeInterval = 300   // 5 minutes
    /// How long to wait after a 429 from the token endpoint.
    private static let rateLimitBackoff: TimeInterval = 600     // 10 minutes

    // MARK: - State (accessed on @MainActor callers via async boundary)

    nonisolated(unsafe) private static var _lastRefreshAttempt: Date?
    nonisolated(unsafe) private static var _rateLimitedUntil: Date?

    // MARK: - Public API

    /// Attempts to refresh the OAuth token using the stored refresh_token.
    ///
    /// - Returns: Fresh `OAuthCredentials` if the refresh succeeded, `nil` if
    ///   the attempt was skipped (too soon) or the endpoint returned an error.
    /// - Throws: `KeychainError` if credentials can't be read/written.
    static func refreshToken() async throws -> OAuthCredentials? {
        // Guard: don't attempt if we're within the rate-limit backoff window
        if let until = _rateLimitedUntil, Date() < until {
            let remaining = Int(until.timeIntervalSinceNow)
            NSLog("[ClaudeUsageBar] Token refresh blocked — rate limited for %d more seconds", remaining)
            return nil
        }

        // Guard: don't attempt more than once per minRefreshInterval
        if let last = _lastRefreshAttempt, Date().timeIntervalSince(last) < minRefreshInterval {
            NSLog("[ClaudeUsageBar] Token refresh skipped — last attempt %d seconds ago (min %d)",
                  Int(Date().timeIntervalSince(last)), Int(minRefreshInterval))
            return nil
        }

        _lastRefreshAttempt = Date()

        // Read current credentials to get the refresh_token
        let current = try KeychainManager.readClaudeCredentials(allowUI: false)

        NSLog("[ClaudeUsageBar] Attempting OAuth token refresh...")

        // Call the token endpoint
        let result = try await callTokenEndpoint(refreshToken: current.refreshToken)

        switch result {
        case .success(let response):
            // Build new credentials and write to Keychain
            let newCreds = OAuthCredentials(
                accessToken: response.accessToken,
                refreshToken: response.refreshToken ?? current.refreshToken,
                expiresAt: response.expiresAt
            )
            try KeychainManager.writeClaudeCredentials(newCreds)
            NSLog("[ClaudeUsageBar] Token refreshed successfully — expires %@",
                  newCreds.expiresAt.description)
            return newCreds

        case .rateLimited(let retryAfter):
            _rateLimitedUntil = Date().addingTimeInterval(retryAfter ?? rateLimitBackoff)
            NSLog("[ClaudeUsageBar] Token endpoint rate limited — backing off %.0f seconds",
                  retryAfter ?? rateLimitBackoff)
            return nil

        case .error(let message):
            NSLog("[ClaudeUsageBar] Token refresh failed: %@", message)
            return nil
        }
    }

    /// Resets rate-limit state (e.g. when the user manually triggers "Poll Now").
    static func resetBackoff() {
        _rateLimitedUntil = nil
        _lastRefreshAttempt = nil
    }

    // MARK: - Network

    private enum RefreshResult {
        case success(TokenResponse)
        case rateLimited(retryAfter: Double?)
        case error(String)
    }

    private struct TokenResponse {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date
    }

    private static func callTokenEndpoint(refreshToken: String) async throws -> RefreshResult {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let (data, httpResponse) = try await session.data(for: request)

        guard let http = httpResponse as? HTTPURLResponse else {
            return .error("Expected HTTP response")
        }

        if http.statusCode == 429 {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            return .rateLimited(retryAfter: retryAfter)
        }

        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "(no body)"
            return .error("HTTP \(http.statusCode): \(body)")
        }

        // Parse the token response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            return .error("Unexpected response format")
        }

        let newRefreshToken = json["refresh_token"] as? String

        // Parse expiry: could be expires_at (absolute) or expires_in (relative)
        let expiresAt: Date
        if let ts = json["expires_at"] as? Double {
            expiresAt = ts > 1e10
                ? Date(timeIntervalSince1970: ts / 1000)
                : Date(timeIntervalSince1970: ts)
        } else if let expiresIn = json["expires_in"] as? Double {
            expiresAt = Date().addingTimeInterval(expiresIn)
        } else {
            // Default to 8 hours if no expiry info
            expiresAt = Date().addingTimeInterval(8 * 3600)
        }

        return .success(TokenResponse(
            accessToken: accessToken,
            refreshToken: newRefreshToken,
            expiresAt: expiresAt
        ))
    }
}
