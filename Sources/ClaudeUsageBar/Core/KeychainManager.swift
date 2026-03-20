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
}
