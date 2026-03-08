import SwiftUI

/// Live countdown that ticks every second using TimelineView.
struct CountdownView: View {
    let resetsAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(countdownText(from: context.date))
        }
    }

    private func countdownText(from now: Date) -> String {
        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining > 0 else { return "Resetting…" }

        let h = Int(remaining) / 3600
        let m = (Int(remaining) % 3600) / 60
        let s = Int(remaining) % 60

        if h > 0 {
            return String(format: "Resets in: %dh %02dm %02ds", h, m, s)
        }
        return String(format: "Resets in: %dm %02ds", m, s)
    }
}

/// Non-live reset display for windows with far-future resets (7-day).
struct ResetDateView: View {
    let resetsAt: Date

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f
    }()

    var body: some View {
        Text("Resets: \(Self.formatter.string(from: resetsAt))")
    }
}
