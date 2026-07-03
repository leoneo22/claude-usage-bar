import AppKit
import SwiftUI
import Combine
import ServiceManagement

/// Set during quit so window controllers don't record teardown-closes
/// as "user closed the window" (which would break state restore).
@MainActor
enum AppState {
    static var isQuitting = false
}

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
        restoreWindowState()
    }

    /// Reopens the desktop widget / floating window if they were visible at last quit.
    private func restoreWindowState() {
        if UserDefaults.standard.bool(forKey: "widgetVisible") {
            widgetWindow.show(provider: provider)
        }
        if UserDefaults.standard.bool(forKey: "floatingVisible") {
            floatingWindow.show(provider: provider)
        }
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
        UserDefaults.standard.set(true, forKey: "floatingVisible")
    }

    // MARK: - Observation

    private func observeProvider() {
        // One observer for all state — fires after any @Published change lands
        provider.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusTitle()
            }
            .store(in: &cancellables)
    }

    /// Menu bar shows the 5-hour %, plus a warning with the worst weekly window
    /// when any weekly limit is running hot (≥ 80%) — prevents surprise lockouts
    /// when the 5-hour window looks fine but a weekly cap is nearly exhausted.
    private func updateStatusTitle() {
        switch provider.error {
        case .authExpired, .keychainDenied, .reauthRequired:
            statusItem?.button?.title = "⚡ ⚠"
            return
        default:
            break
        }

        guard let five = provider.fiveHour else { return }
        let pct = Int(five.utilization.rounded())

        let weeklies = [provider.sevenDay, provider.sevenDayOpus, provider.sevenDaySonnet,
                        provider.sevenDayHaiku, provider.sevenDayCowork]
            .compactMap { $0?.utilization }
        if let worst = weeklies.max(), worst >= 80 {
            statusItem?.button?.title = "⚡ \(pct)% ⚠\(Int(worst.rounded()))%"
        } else {
            statusItem?.button?.title = "⚡ \(pct)%"
        }
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

        // Test Primer (fire immediately for debugging)
        menu.addItem(NSMenuItem(title: "Test Primer Now", action: #selector(testPrimerNow), keyEquivalent: ""))

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
        UserDefaults.standard.set(widgetWindow.isVisible, forKey: "widgetVisible")
    }

    @objc private func moveWidgetHere() {
        widgetWindow.moveToCurrentScreen()
    }

    @objc private func togglePrimer() {
        provider.autoPrimer.isEnabled.toggle()
    }

    @objc private func testPrimerNow() {
        provider.autoPrimer.primeNow()
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
        AppState.isQuitting = true
        provider.stopPolling()
        NSApplication.shared.terminate(nil)
    }
}
