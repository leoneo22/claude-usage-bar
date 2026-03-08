import SwiftUI

struct FooterView: View {
    let lastUpdated: Date?
    let onRefresh: () -> Void

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    var body: some View {
        HStack {
            if let date = lastUpdated {
                Text("Updated \(Self.timeFormatter.string(from: date))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Loading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Poll now")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
