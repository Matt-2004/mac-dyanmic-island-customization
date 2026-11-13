import AppKit

// Menu-bar agent (LSUIElement): no Dock icon, no main menu, lifecycle in AppDelegate.
// When hosting unit tests, skip the app's own startup (no panel, menu, permission prompts).
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let isHostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    if isHostingTests {
        app.setActivationPolicy(.prohibited)
        app.run()
    } else {
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
