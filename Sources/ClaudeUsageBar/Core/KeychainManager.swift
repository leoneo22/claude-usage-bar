import Foundation
import Security
import LocalAuthentication

// MARK: - Errors

enum KeychainError: Error, LocalizedError {
    case notFound
    case accessDenied
    case unexpectedData(String)
    case osError(OSStatus)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "Claude Code credentials not found. Run `claude` in Terminal to authenticate."
        case .accessDenied:
            return "Keychain access denied. Click \"Always Allow\" when prompted to stop repeated password requests."
        case .unexpectedData(let detail):
            return "Credential format unrecognised: \(detail)"
        case .osError(let status):
            let msg = SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "OSStatus \(status)"
            return "Keychain error: \(msg)"
        }
    }

    /// Whether this error means the user denied access — retrying will just prompt again.
    var isAccessDenied: Bool {
        switch self {
        case .accessDenied: return true
        default: return false
        }
    }
}

// MARK: - KeychainManager

/// Reads and writes Claude Code OAuth credentials in the macOS Keychain.
///
/// Security notes:
/// - Never caches tokens — each call reads from Keychain directly.
/// - Never logs credential values.
/// - Writes use the same format Claude Code expects (wrapped in "claudeAiOauth").
enum KeychainManager {
    /// The service name written by Claude Code's `keytar` call.
    static let claudeCodeService = "Claude Code-credentials"

    /// Returns fresh credentials decoded from the Keychain.
    ///
    /// - Parameter allowUI: When `false`, the read fails immediately with `.accessDenied`
    ///   instead of showing a macOS password dialog. Use `false` for automatic/background polls
    ///   so the user isn't interrupted. Use `true` (default) only when the user explicitly
    ///   triggers a refresh (e.g. "Poll Now").
    /// - Throws: ``KeychainError`` on failure.
    static func readClaudeCredentials(allowUI: Bool = true) throws -> OAuthCredentials {
        var query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: claudeCodeService,
            kSecReturnData:  kCFBooleanTrue as Any,
            kSecMatchLimit:  kSecMatchLimitOne,
        ]
        if !allowUI {
            // Use LAContext with interactionNotAllowed to suppress Keychain password dialogs.
            // If the app doesn't have "Always Allow" access, this fails silently with
            // errSecInteractionNotAllowed instead of popping a dialog.
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext] = context
        }

        var raw: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &raw)

        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            throw KeychainError.notFound
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            throw KeychainError.accessDenied
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

    /// Writes refreshed credentials back to Keychain in the format Claude Code expects.
    ///
    /// Reads the existing blob first to preserve any extra fields (scopes, subscriptionType, etc.),
    /// then updates only the token fields.
    static func writeClaudeCredentials(_ creds: OAuthCredentials) throws {
        // Read existing blob to preserve extra fields
        let readQuery: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: claudeCodeService,
            kSecReturnData:  kCFBooleanTrue as Any,
            kSecMatchLimit:  kSecMatchLimitOne,
        ]

        var existingBlob: [String: Any] = [:]
        var raw: AnyObject?
        if SecItemCopyMatching(readQuery as CFDictionary, &raw) == errSecSuccess,
           let data = raw as? Data,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauth = json["claudeAiOauth"] as? [String: Any] {
            existingBlob = oauth
        }

        // Update token fields (store expiresAt as milliseconds, matching Claude Code's format)
        existingBlob["accessToken"] = creds.accessToken
        existingBlob["refreshToken"] = creds.refreshToken
        existingBlob["expiresAt"] = creds.expiresAt.timeIntervalSince1970 * 1000

        let wrapper: [String: Any] = ["claudeAiOauth": existingBlob]
        let data = try JSONSerialization.data(withJSONObject: wrapper)

        // Update existing item (or add if not found)
        let updateQuery: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: claudeCodeService,
        ]
        let attrs: [CFString: Any] = [
            kSecValueData: data,
        ]

        let status = SecItemUpdate(updateQuery as CFDictionary, attrs as CFDictionary)

        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            // Item doesn't exist yet — add it
            var addQuery = updateQuery
            addQuery[kSecValueData] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.osError(addStatus)
            }
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            throw KeychainError.accessDenied
        default:
            throw KeychainError.osError(status)
        }
    }
}
