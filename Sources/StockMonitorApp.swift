import SwiftUI

@main
struct StockMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(MonitorState.shared)
        }
    }
}
