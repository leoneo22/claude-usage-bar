import AppKit
import SwiftUI
import Combine

/// Manages a compact, borderless floating widget showing only the 5-hour usage card.
@MainActor
final class WidgetWindowController: NSObject, NSWindowDelegate {

    private var panel: NSPanel?
    private weak var provider: OAuthUsageProvider?
    private var cancellable: AnyCancellable?

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle(provider: OAuthUsageProvider) {
        if let panel, panel.isVisible {
            close()
        } else {
            show(provider: provider)
        }
    }

    func show(provider: OAuthUsageProvider) {
        if let panel, panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            return
        }

        self.provider = provider

        let view = WidgetView(provider: provider)
        let hosting = NSHostingController(rootView: view)
        hosting.view.setFrameSize(CGSize(width: 240, height: 72))

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 72),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentViewController = hosting
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        // Position bottom-right of the screen where the cursor is
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
        if let screen {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.maxX - 240 - 16
            let y = screenFrame.minY + 16
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    /// Move the widget to the screen where the cursor currently is.
    func moveToCurrentScreen() {
        guard let panel, panel.isVisible else { return }
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
        if let screen {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.maxX - panel.frame.width - 16
            let y = screenFrame.minY + 16
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    func close() {
        panel?.close()
        panel = nil
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
    }
}

// MARK: - Compact widget view

private struct WidgetView: View {
    @ObservedObject var provider: OAuthUsageProvider

    var body: some View {
        Group {
            if let w = provider.fiveHour {
                UsageCardView(title: "5-Hour Window", window: w)
            } else if provider.error != nil {
                compactError
            } else {
                compactLoading
            }
        }
        .frame(width: 240)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var compactLoading: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Fetching…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
    }

    private var compactError: some View {
        Text("⚠ \(provider.error?.localizedDescription ?? "Error")")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(12)
    }
}
