import Foundation
import Security
import LocalAuthentication

// MARK: - Errors

enum KeychainError: Error, LocalizedError {
    case notFound
    case accessDenied
    /// Stored credentials exist but contain blank tokens — transient state while
    /// Claude Code rewrites its blob. Retry shortly; never persist these.
    case emptyTokens
    case unexpectedData(String)
    case osError(OSStatus)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "Claude Code credentials not found. Run `claude` in Terminal to authenticate."
        case .accessDenied:
            return "Keychain access denied. Click \"Always Allow\" when prompted to stop repeated password requests."
        case .emptyTokens:
            return "Claude Code credentials are empty — waiting for it to finish writing."
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
///
/// Two keychain items are used:
///   - `claudeCodeService` ("Claude Code-credentials"): owned by Claude Code CLI.
///     We bootstrap from this ONCE, then never touch it again. Touching it triggers
///     "trusted apps list" ACL prompts that cannot be suppressed from the calling side.
///   - `ownService` ("ClaudeUsageBar-OAuth"): owned by ClaudeUsageBar itself.
///     We create it on first run and use it for all subsequent reads/writes.
///     Because we own it, our app is automatically on its trusted apps list →
///     zero prompts on read/write/refresh.
enum KeychainManager {
    /// The service name written by Claude Code's `keytar` call.
    static let claudeCodeService = "Claude Code-credentials"

    /// Service name for our own copy of the credentials. Owned by ClaudeUsageBar,
    /// so reads/writes don't trigger Keychain trust prompts.
    static let ownService = "ClaudeUsageBar-OAuth"

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

        let creds: OAuthCredentials
        do {
            // Claude Code wraps credentials under a "claudeAiOauth" key
            if let wrapper = try? JSONDecoder().decode([String: OAuthCredentials].self, from: data),
               let wrapped = wrapper["claudeAiOauth"] {
                creds = wrapped
            } else {
                // Fallback: top-level object (older Claude Code versions)
                creds = try JSONDecoder().decode(OAuthCredentials.self, from: data)
            }
        } catch {
            throw KeychainError.unexpectedData(error.localizedDescription)
        }

        // Claude Code sometimes writes blank tokens transiently. Never propagate them.
        guard creds.hasTokens else {
            throw KeychainError.emptyTokens
        }
        return creds
    }

    /// Writes refreshed credentials back to Keychain in the format Claude Code expects.
    ///
    /// **All operations are silent** — uses `LAContext.interactionNotAllowed` to prevent
    /// macOS password dialogs. If Keychain access is denied, the write is skipped silently;
    /// the in-memory token from the refresh response still works for the current session.
    ///
    /// Reads the existing blob first to preserve any extra fields (scopes, subscriptionType, etc.),
    /// then updates only the token fields.
    static func writeClaudeCredentials(_ creds: OAuthCredentials) throws {
        // All Keychain operations must be silent — no password dialogs
        let silentContext = LAContext()
        silentContext.interactionNotAllowed = true

        // Read existing blob to preserve extra fields (silent — skip if denied)
        let readQuery: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: claudeCodeService,
            kSecReturnData:  kCFBooleanTrue as Any,
            kSecMatchLimit:  kSecMatchLimitOne,
            kSecUseAuthenticationContext: silentContext,
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

        // Update existing item (or add if not found) — silent, no password dialogs
        let updateQuery: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: claudeCodeService,
            kSecUseAuthenticationContext: silentContext,
        ]
        let attrs: [CFString: Any] = [
            kSecValueData: data,
        ]

        let status = SecItemUpdate(updateQuery as CFDictionary, attrs as CFDictionary)

        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            // Item doesn't exist yet — add it (also silent)
            let addQuery: [CFString: Any] = [
                kSecClass:       kSecClassGenericPassword,
                kSecAttrService: claudeCodeService,
                kSecValueData:   data,
                kSecUseAuthenticationContext: silentContext,
            ]
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                if addStatus == errSecAuthFailed || addStatus == errSecInteractionNotAllowed {
                    throw KeychainError.accessDenied
                }
                throw KeychainError.osError(addStatus)
            }
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            throw KeychainError.accessDenied
        default:
            throw KeychainError.osError(status)
        }
    }

    // MARK: - Own keychain item (no ACL prompts)

    /// Reads credentials from ClaudeUsageBar's own keychain item.
    /// Returns nil if the item doesn't exist yet (first run).
    ///
    /// Because ClaudeUsageBar created this item, our app is on its trusted apps list
    /// by default — no prompts. We must still pass a kSecUseAuthenticationContext to
    /// avoid Apple's "background credential" UI in some macOS versions.
    static func readOwnCredentials() -> OAuthCredentials? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: ownService,
            kSecReturnData:  kCFBooleanTrue as Any,
            kSecMatchLimit:  kSecMatchLimitOne,
        ]
        var raw: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &raw)
        guard status == errSecSuccess, let data = raw as? Data else {
            return nil
        }
        guard let creds = try? JSONDecoder().decode(OAuthCredentials.self, from: data) else {
            return nil
        }
        // A stored item with blank tokens is unusable and unrecoverable — treat it
        // as absent so callers re-bootstrap from Claude Code instead of looping.
        guard creds.hasTokens else {
            NSLog("[ClaudeUsageBar] Own keychain item has empty tokens — discarding")
            deleteOwnCredentials()
            return nil
        }
        return creds
    }

    /// Writes credentials to ClaudeUsageBar's own keychain item.
    /// Creates the item on first call. Throws only on unrecoverable Keychain errors.
    @discardableResult
    static func writeOwnCredentials(_ creds: OAuthCredentials) -> Bool {
        // Never persist blank tokens — doing so is what broke the app on 2026-08-03.
        guard creds.hasTokens else {
            NSLog("[ClaudeUsageBar] writeOwnCredentials: refused — credentials have empty tokens")
            return false
        }
        let data: Data
        do {
            data = try JSONEncoder().encode(creds)
        } catch {
            NSLog("[ClaudeUsageBar] writeOwnCredentials: encode failed: %@", error.localizedDescription)
            return false
        }

        // Try update first
        let updateQuery: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: ownService,
        ]
        let attrs: [CFString: Any] = [kSecValueData: data]
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attrs as CFDictionary)

        if updateStatus == errSecSuccess {
            return true
        }

        if updateStatus == errSecItemNotFound {
            // First write — add the item. The trusted apps list defaults to "just us".
            let addQuery: [CFString: Any] = [
                kSecClass:       kSecClassGenericPassword,
                kSecAttrService: ownService,
                kSecAttrAccount: "claudeUsageBar",
                kSecValueData:   data,
            ]
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecSuccess {
                NSLog("[ClaudeUsageBar] writeOwnCredentials: created own keychain item")
                return true
            }
            NSLog("[ClaudeUsageBar] writeOwnCredentials: SecItemAdd failed: %d", Int(addStatus))
            return false
        }

        NSLog("[ClaudeUsageBar] writeOwnCredentials: SecItemUpdate failed: %d", Int(updateStatus))
        return false
    }

    /// Deletes ClaudeUsageBar's own keychain item (e.g. when its refresh token
    /// has been invalidated and we need a clean re-bootstrap from Claude Code's item).
    static func deleteOwnCredentials() {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: ownService,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
