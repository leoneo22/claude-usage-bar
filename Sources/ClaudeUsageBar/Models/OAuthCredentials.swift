import Foundation

/// OAuth credentials stored by Claude Code in the Keychain.
/// Claude Code (TypeScript) uses camelCase keys; we also accept snake_case as fallback.
struct OAuthCredentials: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String
    /// Absolute expiry date (converted from ms or seconds as needed).
    let expiresAt: Date

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
}

// MARK: - Dynamic CodingKey

private struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
