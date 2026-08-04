import Foundation

/// OAuth credentials stored by Claude Code in the Keychain.
/// Claude Code (TypeScript) uses camelCase keys; we also accept snake_case as fallback.
struct OAuthCredentials: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    /// Absolute expiry date (converted from ms or seconds as needed).
    let expiresAt: Date

    /// Direct initializer for building credentials from a token refresh response.
    init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)

        // Access token — camelCase first, then snake_case
        if let v = try? c.decode(String.self, forKey: AnyKey("accessToken")) {
            accessToken = v
        } else {
            accessToken = try c.decode(String.self, forKey: AnyKey("access_token"))
        }

        // Refresh token
        if let v = try? c.decode(String.self, forKey: AnyKey("refreshToken")) {
            refreshToken = v
        } else {
            refreshToken = try c.decode(String.self, forKey: AnyKey("refresh_token"))
        }

        // Expiry timestamp: absolute (ms or s) or relative (expires_in seconds)
        if let ts = (try? c.decode(Double.self, forKey: AnyKey("expiresAt")))
                  ?? (try? c.decode(Double.self, forKey: AnyKey("expires_at"))) {
            // Claude Code stores ms (> 1e10); plain OAuth stores s
            expiresAt = ts > 1e10
                ? Date(timeIntervalSince1970: ts / 1000)
                : Date(timeIntervalSince1970: ts)
        } else if let secs = try? c.decode(Double.self, forKey: AnyKey("expires_in")) {
            expiresAt = Date().addingTimeInterval(secs)
        } else {
            // Unknown format — treat as expired so refresh triggers immediately
            expiresAt = .distantPast
        }
    }

    var isExpired: Bool { expiresAt <= Date() }

    /// True when both tokens actually contain a value.
    ///
    /// Claude Code can transiently store empty-string tokens (observed 2026-08-03,
    /// e.g. while re-writing its credential blob). Copying those into our own item
    /// poisons it permanently: an empty refresh_token makes the token endpoint
    /// return `invalid_request_error`, not `invalid_grant`, so recovery never fires.
    /// Never store or use credentials that fail this check.
    var hasTokens: Bool {
        !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Usable right now: real tokens and not past expiry.
    var isUsable: Bool { hasTokens && !isExpired }

    /// Encode to a stable camelCase shape with ms timestamps (matches Claude Code's format).
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(accessToken, forKey: AnyKey("accessToken"))
        try c.encode(refreshToken, forKey: AnyKey("refreshToken"))
        try c.encode(expiresAt.timeIntervalSince1970 * 1000, forKey: AnyKey("expiresAt"))
    }
}

// MARK: - Dynamic CodingKey

private struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
