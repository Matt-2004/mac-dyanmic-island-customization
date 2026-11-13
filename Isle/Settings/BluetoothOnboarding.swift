import AppKit
import SwiftUI

/// Shown when Bluetooth access is denied: explains why Isle needs it and how to enable it.
@MainActor
final class BluetoothOnboardingWindowController: NSObject, NSWindowDelegate {
    private let bluetooth: BluetoothService
    private let settings: AppSettings
    private var window: NSWindow?

    init(bluetooth: BluetoothService, settings: AppSettings) {
        self.bluetooth = bluetooth
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
        let view = BluetoothOnboardingView(
            bluetooth: bluetooth,
            onNotNow: { [weak self] in
                self?.settings.skipBluetoothOnboarding = true
                self?.close()
            },
            onDone: { [weak self] in self?.close() }
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Set Up AirPods"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }
}

struct BluetoothOnboardingView: View {
    let bluetooth: BluetoothService
    let onNotNow: () -> Void
    let onDone: () -> Void

    var body: some View {
        let allowed = bluetooth.permission == .allowed
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: allowed ? "checkmark.seal.fill" : "airpodspro")
                    .font(.system(size: 34))
                    .foregroundStyle(allowed ? Color.green : Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show AirPods in the notch")
                        .font(.title3.bold())
                    Text(allowed ? "Bluetooth access granted." : "Isle needs Bluetooth access.")
                        .foregroundStyle(.secondary)
                }
            }

            Text("Isle uses Bluetooth only to notice when your AirPods connect or disconnect and to show their battery levels. It reads paired devices; it does not scan for or connect to anything.")
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                step(1, "Click **Open System Settings** below.")
                step(2, "In Privacy & Security → Bluetooth, turn on **Isle**.")
                step(3, "Come back and click **Check Again**.")
            }

            HStack {
                if allowed {
                    Spacer()
                    Button("Done", action: onDone)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Not Now", action: onNotNow)
                    Spacer()
                    Button("Check Again") { bluetooth.recheckPermission() }
                    Button("Open System Settings") { bluetooth.openPrivacySettings() }
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
