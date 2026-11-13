import AppKit
import SwiftUI

/// Explains why Isle needs Accessibility and walks the user through granting it.
/// Closes itself shortly after permission is detected.
@MainActor
final class AccessibilityOnboardingWindowController: NSObject, NSWindowDelegate {
    private let coordinator: NotificationCoordinator
    private let settings: AppSettings
    private var window: NSWindow?

    init(coordinator: NotificationCoordinator, settings: AppSettings) {
        self.coordinator = coordinator
        self.settings = settings
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    private func makeWindow() -> NSWindow {
        let view = AccessibilityOnboardingView(
            coordinator: coordinator,
            onNotNow: { [weak self] in
                self?.settings.skipAccessibilityOnboarding = true
                self?.close()
            },
            onDone: { [weak self] in self?.close() }
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Set Up Notifications"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }
}

struct AccessibilityOnboardingView: View {
    @ObservedObject var coordinator: NotificationCoordinator
    let onNotNow: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: coordinator.isAccessibilityTrusted ? "checkmark.seal.fill" : "bell.badge")
                    .font(.system(size: 34))
                    .foregroundStyle(coordinator.isAccessibilityTrusted ? Color.green : Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show notifications in the notch")
                        .font(.title3.bold())
                    Text(coordinator.isAccessibilityTrusted ? "Accessibility access granted." : "Isle needs Accessibility access.")
                        .foregroundStyle(.secondary)
                }
            }

            Text("macOS has no public API for reading other apps' notifications. Isle reads the banners Notification Center draws on screen using the Accessibility API. Nothing leaves your Mac, and only the last 20 notifications are kept in memory.")
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                step(1, "Click **Open System Settings** below.")
                step(2, "In Privacy & Security → Accessibility, turn on **Isle**.")
                step(3, "If Isle isn't listed, click **+** and choose Isle.app.")
                step(4, "Come back here — this window updates by itself.")
            }

            HStack {
                if coordinator.isAccessibilityTrusted {
                    Spacer()
                    Button("Done", action: onDone)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Not Now", action: onNotNow)
                    Spacer()
                    Button("Open System Settings") { coordinator.requestAccessibility() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(text)
        }
    }
}
