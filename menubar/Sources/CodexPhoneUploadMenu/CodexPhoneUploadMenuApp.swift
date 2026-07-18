import AppKit
import SwiftUI

@main
struct CodexPhoneUploadMenuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var coordinator = UploadCoordinator()

    var body: some Scene {
        WindowGroup("Codex 手机传图") {
            MenuContentView(coordinator: coordinator)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            application.activate(ignoringOtherApps: true)
            application.windows.forEach {
                $0.center()
                $0.makeKeyAndOrderFront(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
