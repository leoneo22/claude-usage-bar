import Foundation
import Security

// MARK: - Errors

enum KeychainError: Error, LocalizedError {
    case notFound
    case unexpectedData(String)
    case osError(OSStatus)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "Claude Code credentials not found. Run `claude` in Terminal to authenticate."
        case .unexpectedData(let detail):
            return "Credential format unrecognised: \(detail)"
        case .osError(let status):
            let msg = SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "OSStatus \(status)"
            return "Keychain error: \(msg)"
        }
    }
}

// MARK: - KeychainManager

/// Stateless helper that reads Claude Code OAuth credentials from the macOS Keychain.
///
/// Security notes:
/// - Never caches tokens — each call reads from Keychain directly.
/// - Never logs credential values.
/// - Tokens must be read once, used immediately, then released.
enum KeychainManager {
    /// The service name written by Claude Code's `keytar` call.
    static let claudeCodeService = "Claude Code-credentials"

    /// Returns fresh credentials decoded from the Keychain.
    /// Throws ``KeychainError`` on failure.
    static func readClaudeCredentials() throws -> OAuthCredentials {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: claudeCodeService,
            kSecReturnData:  kCFBooleanTrue as Any,
            kSecMatchLimit:  kSecMatchLimitOne,
        ]

        var raw: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &raw)

        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            throw KeychainError.notFound
        default:
            throw KeychainError.osError(status)
        }

        guard let data = raw as? Data else {
            throw KeychainError.unexpectedData("SecItemCopyMatching did not return Data")
        }

        do {
            // Claude Code wraps credentials under a "claudeAiOauth" key
            if let wrapper = try? JSONDecoder().decode([String: OAuthCredentials].self, from: data),
               let creds = wrapper["claudeAiOauth"] {
                return creds
            }
            // Fallback: top-level object (older Claude Code versions)
            return try JSONDecoder().decode(OAuthCredentials.self, from: data)
        } catch {
            throw KeychainError.unexpectedData(error.localizedDescription)
        }
    }
}
