import SwiftUI

struct ErrorBannerView: View {
    let error: UsageError

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .foregroundStyle(bannerColor)
            Text(error.localizedDescription)
                .font(.caption)
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(bannerColor.opacity(0.12))
    }

    private var bannerColor: Color {
        switch error {
        case .authExpired:    return .orange
        case .keychainDenied: return .orange
        case .rateLimited:    return .yellow
        default:              return .red
        }
    }

    private var iconName: String {
        switch error {
        case .authExpired:    return "lock.fill"
        case .keychainDenied: return "key.fill"
        case .rateLimited:    return "clock.fill"
        default:              return "exclamationmark.triangle.fill"
        }
    }
}
