import SwiftUI

/// Auto-primer toggle row. Wired to AutoPrimer in Step 7.
struct PrimerStatusView: View {
    @Binding var isEnabled: Bool
    let statusText: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Auto-Primer")
                    .font(.subheadline.weight(.semibold))
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
