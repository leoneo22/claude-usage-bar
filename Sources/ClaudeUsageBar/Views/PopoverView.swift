import SwiftUI

// MARK: - PopoverView

struct PopoverView: View {
    @ObservedObject var provider: OAuthUsageProvider
    var onDetach: (() -> Void)? = nil
    var isDetached: Bool = false

    @ObservedObject private var primer: AutoPrimer

    init(provider: OAuthUsageProvider, onDetach: (() -> Void)? = nil, isDetached: Bool = false) {
        self.provider = provider
        self.onDetach = onDetach
        self.isDetached = isDetached
        self.primer = provider.autoPrimer
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let error = provider.error {
                ErrorBannerView(error: error)
                Divider()
            }

            ScrollView {
                VStack(spacing: 10) {
                    if provider.fiveHour == nil {
                        loadingView
                    } else {
                        if let w = provider.fiveHour {
                            UsageCardView(title: "5-Hour Window", window: w)
                        }
                        if let w = provider.sevenDay {
                            UsageCardView(title: "7-Day Window", window: w)
                        }
                        if let w = provider.sevenDayOpus {
                            UsageCardView(title: "7-Day Opus", window: w)
                        }
                        if let w = provider.sevenDaySonnet {
                            UsageCardView(title: "7-Day Sonnet", window: w)
                        }
                        if let w = provider.sevenDayCowork {
                            UsageCardView(title: "7-Day Cowork", window: w)
                        }
                        if let extra = provider.extraUsage, extra.isEnabled {
                            ExtraUsageCardView(extra: extra)
                        }
                        PrimerStatusView(
                            isEnabled: $primer.isEnabled,
                            statusText: primerStatusText
                        )
                    }
                }
                .padding(12)
            }

            Divider()
            FooterView(lastUpdated: provider.lastUpdated, onRefresh: {
                provider.pollNow()
            })
        }
        .frame(width: 300)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Label("Claude Usage", systemImage: "bolt.fill")
                .font(.headline)
            Spacer()
            if let onDetach {
                Button(action: onDetach) {
                    Image(systemName: isDetached ? "pin.slash" : "pin")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help(isDetached ? "Close floating window" : "Detach to floating window")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Computed

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    private var primerStatusText: String {
        guard primer.isEnabled else { return "Disabled" }
        if let next = primer.nextPrimeDate {
            let mins = Int(next.timeIntervalSinceNow / 60)
            return "Primes in ~\(max(0, mins)) min"
        }
        if let last = primer.lastPrimed {
            return "Last primed \(Self.timeFormatter.string(from: last))"
        }
        return "Primes after window resets"
    }

    // MARK: - Loading placeholder

    private var loadingView: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("Fetching usage…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }
}
