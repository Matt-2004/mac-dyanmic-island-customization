import AppKit
import ServiceManagement

/// Runs Isle as a per-user launchd agent (`SMAppService.agent`), so it behaves like a
/// system service: launchd starts it at login and restarts it if it crashes. A normal
/// Quit (exit 0) is respected until the next login.
///
/// The agent plist ships inside the app at `Contents/Library/LaunchAgents`.
@MainActor
final class BackgroundService: ObservableObject {
    static let label = "com.wai.Isle.agent"
    static let plistName = "\(label).plist"

    enum Status: Equatable {
        case running
        case enabled
        case requiresApproval
        case off
        case notInstalled

        var displayText: String {
            switch self {
            case .running: return "Running as a background service"
            case .enabled: return "Enabled — starts at next login"
            case .requiresApproval: return "Waiting for approval in Login Items"
            case .off: return "Off — Isle runs only while opened"
            case .notInstalled: return "Install Isle in /Applications to run it as a service"
            }
        }
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var lastError: String?

    private var service: SMAppService { SMAppService.agent(plistName: Self.plistName) }

    /// True when this process was started by launchd for the agent.
    static var isServiceInstance: Bool {
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label
    }

    /// Only a copy in an Applications folder is registered, so development builds in
    /// DerivedData never become the login service.
    static var isInstalledInApplications: Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        return path.hasPrefix("/Applications/") || path.hasPrefix(home + "/")
    }

    init() {
        refresh()
    }

    func refresh() {
        switch service.status {
        case .enabled:
            status = Self.isServiceInstance ? .running : .enabled
        case .requiresApproval:
            status = .requiresApproval
        case .notRegistered, .notFound:
            status = Self.isInstalledInApplications ? .off : .notInstalled
        @unknown default:
            status = .off
        }
    }

    var isOn: Bool {
        status == .running || status == .enabled || status == .requiresApproval
    }

    /// Called at launch: registers the agent when the setting is on, and moves users of the
    /// older "launch at login" item over to the agent.
    func applyPreference(_ wanted: Bool) {
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
            FileLog.write("service: removed legacy login item")
        }
        guard Self.isInstalledInApplications else {
            refresh()
            return
        }
        let current = service.status
        if wanted, current == .notRegistered || current == .notFound {
            register()
        } else if !wanted, current == .enabled || current == .requiresApproval {
            unregister()
        } else {
            refresh()
        }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            register()
        } else {
            unregister()
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func register() {
        lastError = nil
        do {
            try service.register()
            FileLog.write("service: registered \(Self.label)")
        } catch {
            lastError = error.localizedDescription
            FileLog.write("service: register failed: \(error.localizedDescription)")
        }
        refresh()
    }

    private func unregister() {
        lastError = nil
        let wasServiceInstance = Self.isServiceInstance
        service.unregister { [weak self] error in
            DispatchQueue.main.async {
                if let error {
                    self?.lastError = error.localizedDescription
                    FileLog.write("service: unregister failed: \(error.localizedDescription)")
                } else {
                    FileLog.write("service: unregistered")
                }
                self?.refresh()
                // launchd stops the job's process; quit cleanly if it hasn't already.
                if error == nil, wasServiceInstance {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}

/// Makes sure exactly one Isle runs.
/// - The launchd service instance always wins: older copies are asked to quit.
/// - Opening the installed app while Isle already runs just shows Settings in the
///   running copy (useful when the menu bar icon is hidden).
/// - A development build (not in Applications) takes over from a running copy.
@MainActor
enum SingleInstance {
    private static let yieldName = Notification.Name("com.wai.Isle.yield")
    private static let showSettingsName = Notification.Name("com.wai.Isle.showSettings")
    private static var observers: [NSObjectProtocol] = []

    enum Decision {
        case proceed
        case waitForOthers([NSRunningApplication])
        case exitAfterShowingSettings
    }

    static func otherInstances() -> [NSRunningApplication] {
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.wai.Isle")
            .filter { $0.processIdentifier != me && !$0.isTerminated }
    }

    static func decide() -> Decision {
        let others = otherInstances()
        guard !others.isEmpty else { return .proceed }
        if BackgroundService.isServiceInstance || !BackgroundService.isInstalledInApplications {
            return .waitForOthers(others)
        }
        return .exitAfterShowingSettings
    }

    static func askOthersToQuit() {
        DistributedNotificationCenter.default().postNotificationName(
            yieldName, object: String(ProcessInfo.processInfo.processIdentifier), userInfo: nil, deliverImmediately: true)
    }

    static func askRunningCopyToShowSettings() {
        DistributedNotificationCenter.default().postNotificationName(
            showSettingsName, object: String(ProcessInfo.processInfo.processIdentifier), userInfo: nil, deliverImmediately: true)
    }

    /// Listens for requests from newer copies.
    static func listen(showSettings: @escaping () -> Void) {
        let center = DistributedNotificationCenter.default()
        let me = String(ProcessInfo.processInfo.processIdentifier)
        observers.append(center.addObserver(forName: yieldName, object: nil, queue: .main) { note in
            guard (note.object as? String) != me else { return }
            FileLog.write("instance: yielding to pid \(note.object as? String ?? "?")")
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        })
        observers.append(center.addObserver(forName: showSettingsName, object: nil, queue: .main) { note in
            guard (note.object as? String) != me else { return }
            MainActor.assumeIsolated { showSettings() }
        })
    }

    /// Calls `completion` once all `others` have exited, or after `timeout` (then force-quits them).
    static func waitUntilGone(_ others: [NSRunningApplication], timeout: TimeInterval = 4, completion: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func check() {
            let alive = others.filter { !$0.isTerminated }
            if alive.isEmpty {
                completion()
            } else if Date() >= deadline {
                alive.forEach { $0.forceTerminate() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { completion() }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { check() }
            }
        }
        check()
    }
}
