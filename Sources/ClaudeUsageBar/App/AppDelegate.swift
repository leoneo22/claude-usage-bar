import AppKit
import SwiftUI
import Combine
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - UI

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let floatingWindow = FloatingWindowController()
    private let widgetWindow = WidgetWindowController()

    // MARK: - Data

    let provider = OAuthUsageProvider()
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupPopover()
        observeProvider()
        provider.startPolling()
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem?.button else { return }
        button.title = "⚡ --%"
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        button.action = #selector(statusBarButtonClicked)
        button.target = self
        // Receive both left and right mouse events so we can differentiate them
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    // MARK: - Popover

    private func setupPopover() {
        let view = PopoverView(provider: provider, onDetach: { [weak self] in
            self?.detachToFloatingWindow()
        })
        let hosting = NSHostingController(rootView: view)

        let p = NSPopover()
        p.contentViewController = hosting
        p.behavior = .transient
        p.contentSize = CGSize(width: 300, height: 380)
        popover = p
    }

    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            // Right-click → context menu
            let menu = buildMenu()
            statusItem?.menu = menu
            sender.performClick(nil)
            statusItem?.menu = nil
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// Called by the pin button in PopoverView.
    func detachToFloatingWindow() {
        popover?.performClose(nil)
        floatingWindow.show(provider: provider)
    }

    // MARK: - Observation

    private func observeProvider() {
        provider.$fiveHour
            .receive(on: RunLoop.main)
            .sink { [weak self] window in
                guard let window else { return }
                let pct = Int(window.utilization.rounded())
                self?.statusItem?.button?.title = "⚡ \(pct)%"
            }
            .store(in: &cancellables)

        provider.$error
            .receive(on: RunLoop.main)
            .sink { [weak self] error in
                guard error != nil else { return }
                switch error {
                case .authExpired, .keychainDenied:
                    self?.statusItem?.button?.title = "⚡ ⚠"
                default:
                    break
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Menu

    func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // Poll Now
        menu.addItem(NSMenuItem(title: "Poll Now", action: #selector(pollNow), keyEquivalent: "r"))

        menu.addItem(.separator())

        // Auto-Primer toggle
        let primerItem = NSMenuItem(title: "Auto-Primer", action: #selector(togglePrimer), keyEquivalent: "")
        primerItem.state = provider.autoPrimer.isEnabled ? .on : .off
        menu.addItem(primerItem)

        // Desktop Widget toggle
        let widgetItem = NSMenuItem(title: "Desktop Widget", action: #selector(toggleWidget), keyEquivalent: "")
        widgetItem.state = widgetWindow.isVisible ? .on : .off
        menu.addItem(widgetItem)

        // Move Widget Here (only shown when widget is visible)
        if widgetWindow.isVisible {
            let moveItem = NSMenuItem(title: "Move Widget Here", action: #selector(moveWidgetHere), keyEquivalent: "")
            menu.addItem(moveItem)
        }

        // Start at Login toggle
        let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleStartAtLogin), keyEquivalent: "")
        loginItem.state = startAtLogin ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit ClaudeUsageBar", action: #selector(quit), keyEquivalent: "q"))
        return menu
    }

    @objc private func pollNow() {
        provider.pollNow()
    }

    @objc private func toggleWidget() {
        widgetWindow.toggle(provider: provider)
    }

    @objc private func moveWidgetHere() {
        widgetWindow.moveToCurrentScreen()
    }

    @objc private func togglePrimer() {
        provider.autoPrimer.isEnabled.toggle()
    }

    @objc private func toggleStartAtLogin() {
        do {
            if startAtLogin {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("[ClaudeUsageBar] Start at Login error: %@", error.localizedDescription)
        }
    }

    private var startAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func quit() {
        provider.stopPolling()
        NSApplication.shared.terminate(nil)
    }
}
