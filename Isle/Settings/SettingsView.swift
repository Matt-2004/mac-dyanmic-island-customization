import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let notifications: NotificationCoordinator
    let devices: DevicesCoordinator
    let backgroundService: BackgroundService
    let showOnboarding: () -> Void

    var body: some View {
        TabView {
            GeneralSettingsView(settings: settings, service: backgroundService)
                .tabItem { Label("General", systemImage: "gearshape") }
            NotificationSettingsView(settings: settings, coordinator: notifications, showOnboarding: showOnboarding)
                .tabItem { Label("Notifications", systemImage: "bell") }
            DevicesSettingsView(settings: settings, devices: devices)
                .tabItem { Label("Devices", systemImage: "battery.75percent") }
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520)
        .padding(20)
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var service: BackgroundService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Form {
            Section("Background service") {
                Toggle("Run Isle as a background service", isOn: $settings.runAsService)
                    .disabled(!BackgroundService.isInstalledInApplications)
                Text("Starts by itself when you log in and restarts if it crashes — you never need to open it. Turning this off quits Isle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Status") {
                    Text(service.status.displayText)
                        .foregroundStyle(service.status == .running ? .green : .secondary)
                }
                if service.status == .requiresApproval {
                    HStack {
                        Text("Allow Isle under “Allow in the Background”.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { service.openLoginItemsSettings() }
                    }
                }
                if let error = service.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Toggle("Show icon in menu bar", isOn: $settings.showMenuBarIcon)
                Text("When the icon is hidden, open Isle from Applications or Spotlight to get to Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onAppear { service.refresh() }

            Section("Music") {
                Toggle("Also follow Spotify", isOn: $settings.spotifyEnabled)
                Toggle("Find missing album covers online (Apple iTunes Search)", isOn: $settings.fetchMissingArtwork)
                Text("Covers are looked up only when the player provides none; the artist and song title are sent to Apple's public iTunes Search API.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Island") {
                LabeledContent("Hover delay") {
                    HStack {
                        Slider(value: $settings.hoverDelay, in: 0...1.5, step: 0.05)
                        Text(String(format: "%.2f s", settings.hoverDelay))
                            .monospacedDigit()
                            .frame(width: 54, alignment: .trailing)
                    }
                }
                Toggle("Hide the island over full-screen apps (notifications still show)", isOn: $settings.hideInFullScreen)
                LabeledContent("Reduce Motion") {
                    Text(reduceMotion ? "On — island fades instead of springing" : "Off (follows System Settings → Accessibility → Display)")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct NotificationSettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var coordinator: NotificationCoordinator
    let showOnboarding: () -> Void
    @State private var dumpMessage: String?

    var body: some View {
        Form {
            Section {
                Toggle("Show notifications in the notch", isOn: $settings.notificationsEnabled)
                LabeledContent("Accessibility") {
                    if coordinator.isAccessibilityTrusted {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Set Up…", action: showOnboarding)
                    }
                }
                Toggle("Close the macOS banner when Isle shows it", isOn: $settings.closeSystemBanners)
                Text("Avoids seeing the same notification twice. Closing a banner also removes it from Notification Center, so it won't be in the list later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Peek duration") {
                    HStack {
                        Slider(value: $settings.peekDuration, in: 2...10, step: 0.5)
                        Text(String(format: "%.1f s", settings.peekDuration))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }

            Section("Recent (last \(NotificationCoordinator.historyLimit))") {
                if coordinator.history.isEmpty {
                    Text("No notifications yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(coordinator.history) { item in
                        HistoryRow(
                            item: item,
                            isBlocked: settings.isBlocked(item.blocklistKey),
                            onOpen: { coordinator.open(item) },
                            onBlock: { settings.block(item.blocklistKey) },
                            onDismiss: { coordinator.remove(item) }
                        )
                    }
                    Button("Clear All", role: .destructive) { coordinator.clearHistory() }
                }
            }

            Section {
                if settings.blockedApps.isEmpty {
                    Text("None. Use the hand icon on a recent notification, or Add App….")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(settings.blockedApps, id: \.self) { key in
                        HStack {
                            Text(AppDisplay.name(for: key))
                            Spacer()
                            Text(key).font(.caption).foregroundStyle(.secondary)
                            Button("Unblock") { settings.unblock(key) }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Blocked apps")
                    Spacer()
                    Button("Add App…") { chooseAppToBlock() }
                        .controlSize(.small)
                }
            }

            Section("Icons") {
                Toggle("Download icons for web services (Messenger, Gmail, …)", isOn: $settings.webIconsEnabled)
                Text("Installed apps always use their own icon. For notifications from websites, Isle fetches the site's public icon once (only the domain, e.g. messenger.com, is contacted) and caches it. Otherwise a lettered badge is shown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Clear Downloaded Icons") { AppIconProvider.shared.clearWebIconCache() }
            }

            Section("Fallback source") {
                Toggle("Also read the usernoted database", isOn: $settings.usernotedFallbackEnabled)
                Text("Catches notifications whose banners Isle can't read (e.g. banner style None). Needs Full Disk Access. Uses a private, undocumented database that may change with macOS updates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settings.usernotedFallbackEnabled {
                    LabeledContent("Status") {
                        Text(coordinator.usernotedStatus.displayText)
                            .foregroundStyle(.secondary)
                    }
                    if coordinator.usernotedStatus == .needsFullDiskAccess {
                        HStack {
                            Button("Open Full Disk Access") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            Button("Retry") { coordinator.retryUsernoted() }
                        }
                    }
                }
            }

            Section("Debugging") {
                Toggle("Dump Notification Center AX tree on every change", isOn: $settings.axDumpEnabled)
                Text("Writes to ~/Library/Logs/Isle/ax-dump.txt. The file contains notification text — turn this off when done.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Dump Now") {
                        coordinator.dumpAXTreeNow { written in
                            dumpMessage = written ? "Written." : "Not written — Accessibility not granted?"
                        }
                    }
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([AXTreeDumper.dumpFileURL])
                    }
                    if let dumpMessage {
                        Text(dumpMessage).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 560)
    }

    private func chooseAppToBlock() {
        let panel = NSOpenPanel()
        panel.title = "Block notifications from…"
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let bundleID = Bundle(url: url)?.bundleIdentifier {
                settings.block(bundleID)
            }
        }
    }
}

private struct DevicesSettingsView: View {
    @ObservedObject var settings: AppSettings
    let devices: DevicesCoordinator

    var body: some View {
        let power = devices.power
        let bluetooth = devices.bluetooth
        Form {
            Section("Mac battery") {
                Toggle("Peek when charger is plugged in / unplugged / full", isOn: $settings.chargingPeekEnabled)
                Toggle("Low battery alerts (20% and 10%)", isOn: $settings.lowBatteryAlertsEnabled)
                Toggle("Always show battery to the right of the notch", isOn: $settings.alwaysShowBattery)
                Toggle("Show charging indicator next to the notch", isOn: $settings.chargingIndicatorEnabled)
                    .disabled(settings.alwaysShowBattery)
                LabeledContent("Now") {
                    if let snapshot = power.snapshot {
                        Text("\(snapshot.percent)% · \(snapshot.statusText)")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No internal battery").foregroundStyle(.secondary)
                    }
                }
            }

            Section("AirPods") {
                Toggle("Peek when AirPods connect / disconnect", isOn: $settings.airpodsPeekEnabled)
                Picker("Devices", selection: $settings.bluetoothScope) {
                    ForEach(BluetoothScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                LabeledContent("Bluetooth access") {
                    switch bluetooth.permission {
                    case .allowed:
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .notDetermined:
                        Text("Not asked yet").foregroundStyle(.secondary)
                    case .denied:
                        Button("Set Up…") { devices.showBluetoothOnboarding() }
                    }
                }
                if bluetooth.devices.isEmpty {
                    Text("No matching device connected.").foregroundStyle(.secondary)
                } else {
                    ForEach(bluetooth.devices) { device in
                        LabeledContent {
                            Text(DevicesRowView.batterySummary(device.battery))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        } label: {
                            Label(device.name, systemImage: device.kind.symbolName)
                        }
                    }
                }
                Text("Battery levels come from System Information (system_profiler), refreshed on connect, every 60 s while connected, and when you open the island. \"--\" means macOS hasn't reported that value yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct HistoryRow: View {
    let item: IslandNotification
    let isBlocked: Bool
    let onOpen: () -> Void
    let onBlock: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AppIconView(notification: item, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(item.title).bold().lineLimit(1)
                    Spacer()
                    Text(item.date, style: .time).font(.caption).foregroundStyle(.secondary)
                }
                Text(item.appName).font(.caption).foregroundStyle(.secondary)
                if let body = item.body {
                    Text(body).lineLimit(2)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
            Button(action: onBlock) {
                Image(systemName: "hand.raised")
            }
            .buttonStyle(.borderless)
            .disabled(isBlocked)
            .help(isBlocked ? "Already blocked" : "Block notifications from \(item.appName)")
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
    }
}

enum AppDisplay {
    /// Display name for a blocklist key (bundle ID or app name).
    static func name(for key: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key) else { return key }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

private struct AboutSettingsView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "capsule.fill")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Isle")
                .font(.title2.bold())
            Text(version)
                .foregroundStyle(.secondary)
            Text("Apple Music and notifications in your notch.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }
}
