import AppKit
import SwiftUI

/// Hosts the SwiftUI settings view in a regular window. Because Isle is an
/// agent app, the window is activated explicitly so it comes to the front.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let settings: AppSettings
    private let notifications: NotificationCoordinator
    private let devices: DevicesCoordinator
    private let backgroundService: BackgroundService
    private let showOnboarding: () -> Void
    private var window: NSWindow?

    init(settings: AppSettings, notifications: NotificationCoordinator, devices: DevicesCoordinator,
         backgroundService: BackgroundService, showOnboarding: @escaping () -> Void) {
        self.backgroundService = backgroundService
        self.settings = settings
        self.notifications = notifications
        self.devices = devices
        self.showOnboarding = showOnboarding
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView(settings: settings, notifications: notifications, devices: devices, backgroundService: backgroundService, showOnboarding: showOnboarding))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Isle Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("IsleSettingsWindow")
        return window
    }
}
