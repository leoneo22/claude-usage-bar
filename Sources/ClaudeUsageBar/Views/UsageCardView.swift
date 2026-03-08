import SwiftUI

// MARK: - Reusable progress-bar card

struct UsageCardView: View {
    let title: String
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(String(format: "%.1f%%", window.utilization))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(barColor)
            }

            UsageBar(value: window.utilization)

            // Reset info
            if let resetsAt = window.resetsAt {
                CountdownView(resetsAt: resetsAt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var barColor: Color { UsageBar.color(for: window.utilization) }
}

// MARK: - Extra usage card (credits-based)

struct ExtraUsageCardView: View {
    let extra: ExtraUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Extra Usage")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let used = extra.usedCredits {
                    Text(String(format: "$%.2f", used / 100))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.blue)
                }
            }

            if let util = extra.utilization {
                UsageBar(value: util)
            }

            if let limit = extra.monthlyLimit, let used = extra.usedCredits {
                Text(String(format: "$%.2f / $%.2f", used / 100, limit / 100))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No monthly limit set")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Progress bar

struct UsageBar: View {
    let value: Double // 0–100

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.secondary.opacity(0.2))
                Capsule()
                    .fill(Self.color(for: value))
                    .frame(width: max(0, geo.size.width * CGFloat(value) / 100))
            }
        }
        .frame(height: 8)
    }

    static func color(for value: Double) -> Color {
        if value < 50 { return .green }
        if value < 80 { return .yellow }
        return .red
    }
}
