import Foundation

// MARK: - API response models

struct UsageWindow: Decodable, Sendable {
    /// Utilization percentage 0–100 (clamped).
    let utilization: Double
    /// When this window resets (nil means rolling / no hard reset).
    let resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        utilization = min(100, max(0, try c.decode(Double.self, forKey: .utilization)))
        resetsAt = try c.decodeIfPresent(Date.self, forKey: .resetsAt)
    }
}

struct ExtraUsage: Decodable, Sendable {
    let isEnabled: Bool
    let usedCredits: Double?
    let utilization: Double?
    let monthlyLimit: Double?

    enum CodingKeys: String, CodingKey {
        case isEnabled    = "is_enabled"
        case usedCredits  = "used_credits"
        case utilization
        case monthlyLimit = "monthly_limit"
    }
}

struct UsageResponse: Decodable, Sendable {
    let fiveHour: UsageWindow
    let sevenDay: UsageWindow?
    let sevenDayOpus: UsageWindow?
    let sevenDaySonnet: UsageWindow?
    let sevenDayCowork: UsageWindow?
    let extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour        = "five_hour"
        case sevenDay        = "seven_day"
        case sevenDayOpus    = "seven_day_opus"
        case sevenDaySonnet  = "seven_day_sonnet"
        case sevenDayCowork  = "seven_day_cowork"
        case extraUsage      = "extra_usage"
    }
}

// MARK: - Error types

enum UsageError: Error, LocalizedError, Sendable {
    case authExpired
    case rateLimited
    case httpError(Int)
    case networkError(String)
    case credentialError(String)

    var errorDescription: String? {
        switch self {
        case .authExpired:
            return "Auth expired — re-authenticating…"
        case .rateLimited:
            return "Rate limited (429) — backing off"
        case .httpError(let code):
            return "HTTP \(code)"
        case .networkError(let msg):
            return "Network error: \(msg)"
        case .credentialError(let msg):
            return "Credential error: \(msg)"
        }
    }

    /// Whether a token refresh should be attempted after this error.
    var shouldRefreshToken: Bool { self == .authExpired }
}

extension UsageError: Equatable {
    static func == (lhs: UsageError, rhs: UsageError) -> Bool {
        switch (lhs, rhs) {
        case (.authExpired, .authExpired), (.rateLimited, .rateLimited): return true
        case (.httpError(let a), .httpError(let b)): return a == b
        default: return false
        }
    }
}
