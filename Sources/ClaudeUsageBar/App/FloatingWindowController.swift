import AppKit
import SwiftUI

/// Manages the always-on-top detached panel shown when the user clicks the pin button.
@MainActor
final class FloatingWindowController: NSObject, NSWindowDelegate {

    private var panel: NSPanel?
    private weak var provider: OAuthUsageProvider?

    func show(provider: OAuthUsageProvider) {
        // Bring existing panel to front if already visible
        if let panel, panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            return
        }

        self.provider = provider

        let view = PopoverView(
            provider: provider,
            onDetach: { [weak self] in self?.close() },
            isDetached: true
        )
        let hosting = NSHostingController(rootView: view)
        hosting.view.setFrameSize(CGSize(width: 300, height: 380))

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 380),
            styleMask:   [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        panel.title = "Claude Usage"
        panel.titlebarAppearsTransparent = true
        panel.contentViewController = hosting
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.center()
        panel.makeKeyAndOrderFront(nil)

        self.panel = panel
    }

    func close() {
        panel?.close()
    }

    // NSWindowDelegate — clear reference when the window closes via its × button
    func windowWillClose(_ notification: Notification) {
        panel = nil
    }
}
