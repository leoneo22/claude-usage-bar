import Foundation

/// Handles stale-token recovery by re-reading the Keychain after a 401.
///
/// Strategy: Claude Code manages its own OAuth refresh. When it refreshes a token it
/// immediately updates the Keychain entry. After a 401 we just wait briefly and re-read
/// Keychain — no need to know the OAuth client_id or replicate the refresh flow.
enum TokenRefresher {
    private static let waitSeconds: Double = 2

    /// Called after a 401 response. Waits briefly, then re-reads Keychain.
    /// - Returns: Fresh `OAuthCredentials` if Claude Code has already refreshed, `nil` otherwise.
    static func waitForTokenRefresh() async throws -> OAuthCredentials? {
        try await Task.sleep(for: .seconds(waitSeconds))
        let creds = try KeychainManager.readClaudeCredentials()
        return creds.isExpired ? nil : creds
    }
}
