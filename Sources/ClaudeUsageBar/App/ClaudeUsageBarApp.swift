import SwiftUI

@main
struct ClaudeUsageBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Menu bar only app — no windows needed.
        // Settings scene is a placeholder to satisfy SwiftUI App requirements.
        Settings {
            EmptyView()
        }
    }
}
