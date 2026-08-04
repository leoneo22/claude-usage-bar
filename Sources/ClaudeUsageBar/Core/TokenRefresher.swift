import Foundation

/// Handles stale-token recovery via the OAuth refresh_token flow.
///
/// Calls the Anthropic token endpoint directly — no CLI dependency.
/// Writes refreshed credentials back to Keychain so Claude Code stays in sync.
///
/// **Rate-limit discipline:** At most one refresh per `minRefreshInterval`.
/// If the endpoint returns 429, backs off for `rateLimitBackoff` before retrying.
@MainActor
enum TokenRefresher {

    // MARK: - Configuration

    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let clientID  = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    /// Minimum time between refresh attempts (prevents hammering the endpoint).
    private static let minRefreshInterval: TimeInterval = 300   // 5 minutes
    /// How long to wait after a 429 from the token endpoint.
    private static let rateLimitBackoff: TimeInterval = 600     // 10 minutes

    // MARK: - State (@MainActor-isolated)

    private static var _lastRefreshAttempt: Date?
    private static var _rateLimitedUntil: Date?

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

        // Read current refresh_token from our own item (silent), with a fallback to
        // Claude Code's item. readOwnCredentials returns nil for blank-token items,
        // so an empty token can never reach the endpoint.
        let currentRefreshToken: String
        if let own = KeychainManager.readOwnCredentials() {
            currentRefreshToken = own.refreshToken
        } else {
            let bootstrap = try KeychainManager.readClaudeCredentials(allowUI: false)
            currentRefreshToken = bootstrap.refreshToken
            KeychainManager.writeOwnCredentials(bootstrap)
            // Claude Code's token may already be usable — skip a pointless refresh
            if bootstrap.isUsable {
                NSLog("[ClaudeUsageBar] Recovered usable credentials from Claude Code")
                return bootstrap
            }
        }

        NSLog("[ClaudeUsageBar] Attempting OAuth token refresh...")

        // Call the token endpoint
        let result = try await callTokenEndpoint(refreshToken: currentRefreshToken)

        switch result {
        case .success(let response):
            let newCreds = OAuthCredentials(
                accessToken: response.accessToken,
                refreshToken: response.refreshToken ?? currentRefreshToken,
                expiresAt: response.expiresAt
            )
            // Write to OUR keychain item — we own it, no ACL prompt.
            // We deliberately do NOT write back to Claude Code's item.
            // Touching Claude Code's item triggers trusted-apps-list prompts
            // that cannot be suppressed from the calling side.
            let wrote = KeychainManager.writeOwnCredentials(newCreds)
            NSLog("[ClaudeUsageBar] Token refreshed — own keychain write %@. Expires %@",
                  wrote ? "OK" : "FAILED", newCreds.expiresAt.description)
            return newCreds

        case .rateLimited(let retryAfter):
            _rateLimitedUntil = Date().addingTimeInterval(retryAfter ?? rateLimitBackoff)
            NSLog("[ClaudeUsageBar] Token endpoint rate limited — backing off %.0f seconds",
                  retryAfter ?? rateLimitBackoff)
            return nil

        case .error(let message):
            NSLog("[ClaudeUsageBar] Token refresh failed: %@", message)
            // ANY refresh failure means our stored token can't be used: revoked
            // (invalid_grant), malformed (invalid_request_error), or otherwise
            // rejected. Claude Code's item may hold working credentials, so always
            // try to recover from it rather than failing permanently.
            //
            // Scoping this to invalid_grant is exactly what left the app dead from
            // 2026-08-03: a blank stored token produced invalid_request_error, which
            // fell through this branch and never recovered.
            return try await rebootstrapFromClaudeCode(failedRefreshToken: currentRefreshToken)
        }
    }

    /// Recovers from a revoked refresh token by re-reading Claude Code's keychain item.
    ///
    /// Silent read — if the user granted "Always Allow" during the original bootstrap,
    /// this self-heals with zero prompts. Returns nil if Claude Code's item is
    /// inaccessible or holds the same dead token.
    private static func rebootstrapFromClaudeCode(failedRefreshToken: String) async throws -> OAuthCredentials? {
        NSLog("[ClaudeUsageBar] Refresh token revoked — attempting re-bootstrap from Claude Code's keychain item")

        let cli: OAuthCredentials
        do {
            cli = try KeychainManager.readClaudeCredentials(allowUI: false)
        } catch {
            NSLog("[ClaudeUsageBar] Re-bootstrap failed — can't read Claude Code's item: %@", error.localizedDescription)
            return nil
        }

        guard cli.refreshToken != failedRefreshToken else {
            NSLog("[ClaudeUsageBar] Re-bootstrap aborted — Claude Code has the same revoked token. Run `claude` in Terminal to re-authenticate.")
            throw UsageError.reauthRequired
        }

        // Claude Code has different credentials — adopt them.
        // writeOwnCredentials refuses blank tokens, and readClaudeCredentials
        // already rejected them, so we can't re-poison our item here.
        KeychainManager.deleteOwnCredentials()
        KeychainManager.writeOwnCredentials(cli)

        if !cli.isExpired {
            NSLog("[ClaudeUsageBar] Re-bootstrap succeeded — using Claude Code's current access token")
            return cli
        }

        // CLI's access token is expired too — refresh with its newer refresh token
        NSLog("[ClaudeUsageBar] Re-bootstrapped refresh token found, access token expired — refreshing")
        let result = try await callTokenEndpoint(refreshToken: cli.refreshToken)
        guard case .success(let response) = result else {
            NSLog("[ClaudeUsageBar] Re-bootstrap refresh also failed. Run `claude` in Terminal to re-authenticate.")
            throw UsageError.reauthRequired
        }
        let creds = OAuthCredentials(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? cli.refreshToken,
            expiresAt: response.expiresAt
        )
        KeychainManager.writeOwnCredentials(creds)
        NSLog("[ClaudeUsageBar] Re-bootstrap + refresh succeeded — expires %@", creds.expiresAt.description)
        return creds
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
