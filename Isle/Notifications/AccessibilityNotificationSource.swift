import ApplicationServices
import AppKit
import OSLog

/// Reads notification banners from the `NotificationCenter` process through the
/// Accessibility API.
///
/// All AX work happens on a dedicated thread with its own run loop (AX calls
/// can block when the target is busy). An `AXObserver` triggers scans on
/// window/layout changes, and a 1 s poll covers notifications AX misses.
/// Each scan diffs the visible banners against the previous scan so a banner is
/// reported once, when it appears. Banners are identified by their own AXIdentifier
/// (unique per delivered notification), so two identical messages both peek, while
/// the same banner reappearing in the Notification Center panel does not.
final class AccessibilityNotificationSource: NotificationSource {
    static let notificationCenterBundleID = "com.apple.notificationcenterui"

    let name = "Accessibility"

    private let log = Logger(subsystem: "com.wai.Isle", category: "notifications")
    private let worker = RunLoopThread(name: "com.wai.Isle.ax")
    private let dumper = AXTreeDumper()
    private let stateLock = NSLock()

    // Mutated only on the worker thread.
    private var appElement: AXUIElement?
    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var pollTimer: Timer?
    private var visibleIdentities: Set<String> = []
    /// Identity → last time it was on screen. Prevents re-peeking a banner that
    /// reappears (e.g. in the Notification Center panel) within `recentWindow`.
    /// Identities are per-notification, so this never hides a *new* identical message
    /// (unless macOS gives a banner no identifier, where content is the fallback identity).
    private var recentlySeen: [String: Date] = [:]
    private let recentWindow: TimeInterval = 600
    private var hasSeeded = false
    private var scanScheduled = false

    // Guarded by stateLock.
    private var _handler: ((IslandNotification) -> Void)?
    private var _isRunning = false
    private var _dumpEnabled = false
    private var _closesSystemBanners = false

    private var workspaceObservers: [NSObjectProtocol] = []

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isRunning
    }

    /// When true, every change in the NotificationCenter tree is appended to ax-dump.txt.
    var dumpEnabled: Bool {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _dumpEnabled
        }
        set {
            stateLock.lock()
            _dumpEnabled = newValue
            stateLock.unlock()
        }
    }

    /// When true, the macOS banner is closed right after Isle shows its own peek.
    /// Closing a banner also removes it from Notification Center.
    var closesSystemBanners: Bool {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _closesSystemBanners
        }
        set {
            stateLock.lock()
            _closesSystemBanners = newValue
            stateLock.unlock()
        }
    }

    func start(handler: @escaping (IslandNotification) -> Void) {
        stateLock.lock()
        _handler = handler
        _isRunning = true
        stateLock.unlock()

        if workspaceObservers.isEmpty {
            let center = NSWorkspace.shared.notificationCenter
            // NotificationCenter is relaunched by the system occasionally; re-attach when it is.
            workspaceObservers.append(center.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == Self.notificationCenterBundleID else { return }
                self?.worker.perform { self?.attach() }
            })
        }

        worker.perform { [weak self] in
            self?.attach()
            self?.startPolling()
        }
    }

    func stop() {
        stateLock.lock()
        _isRunning = false
        _handler = nil
        stateLock.unlock()
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        worker.perform { [weak self] in
            self?.detach()
            self?.pollTimer?.invalidate()
            self?.pollTimer = nil
        }
    }

    /// Writes the current tree to ax-dump.txt regardless of the dump toggle.
    func dumpNow(completion: @escaping (Bool) -> Void) {
        worker.perform { [weak self] in
            guard let self else { return }
            if self.appElement == nil { self.attach() }
            var written = false
            if let app = self.appElement {
                let banners = BannerParser.banners(in: app)
                written = self.dumper.dumpIfChanged(
                    root: app, reason: "manual dump", extra: BannerParser.summary(banners), force: true
                )
            }
            DispatchQueue.main.async { completion(written) }
        }
    }

    // MARK: Worker thread

    private func attach() {
        guard isRunning else { return }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.notificationCenterBundleID).first else {
            log.error("NotificationCenter process not found")
            FileLog.write("ax: NotificationCenter process not found")
            return
        }
        let pid = app.processIdentifier
        if pid == observedPID, observer != nil { return }
        detach()

        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 1.0)
        appElement = element
        observedPID = pid

        var newObserver: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let source = Unmanaged<AccessibilityNotificationSource>.fromOpaque(refcon).takeUnretainedValue()
            source.scheduleScan()
        }
        guard AXObserverCreate(pid, callback, &newObserver) == .success, let newObserver else {
            log.error("AXObserverCreate failed for NotificationCenter pid \(pid)")
            FileLog.write("ax: AXObserverCreate failed for pid \(pid)")
            return
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let notifications = [
            kAXWindowCreatedNotification,
            kAXCreatedNotification,
            kAXUIElementDestroyedNotification,
            kAXLayoutChangedNotification,
            kAXValueChangedNotification
        ]
        var registered = 0
        for notification in notifications
        where AXObserverAddNotification(newObserver, element, notification as CFString, refcon) == .success {
            registered += 1
        }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(newObserver), .defaultMode)
        observer = newObserver
        FileLog.write("ax: attached to NotificationCenter pid \(pid), \(registered) notifications registered")
        log.notice("Attached to NotificationCenter pid \(pid), \(registered) AX notifications registered")

        hasSeeded = false
        scan()
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        appElement = nil
        observedPID = 0
    }

    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.scan()
        }
        timer.tolerance = 0.2
        RunLoop.current.add(timer, forMode: .default)
        pollTimer = timer
    }

    /// Coalesces bursts of AX callbacks into one scan shortly after.
    private func scheduleScan() {
        guard !scanScheduled else { return }
        scanScheduled = true
        worker.perform(after: 0.15) { [weak self] in
            self?.scanScheduled = false
            self?.scan()
        }
    }

    private func scan() {
        guard isRunning else { return }
        if appElement == nil {
            attach()
        }
        guard let app = appElement else { return }

        let banners = BannerParser.banners(in: app)

        if dumpEnabled {
            dumper.dumpIfChanged(root: app, reason: "tree changed", extra: BannerParser.summary(banners))
        }

        let now = Date()
        recentlySeen = recentlySeen.filter { now.timeIntervalSince($0.value) < recentWindow }
        let current = Set(banners.map(\.identity))
        let newBanners = banners.filter {
            !visibleIdentities.contains($0.identity) && recentlySeen[$0.identity] == nil
        }
        visibleIdentities = current
        for identity in current {
            recentlySeen[identity] = now
        }

        guard hasSeeded else {
            // First scan after attaching: whatever is already on screen is not "new".
            hasSeeded = true
            return
        }
        if !newBanners.isEmpty {
            FileLog.write("ax: \(newBanners.count) new banner(s), panel=\(newBanners.map(\.isInHistoryPanel))")
        }
        let fresh = newBanners.filter { !$0.isInHistoryPanel }
        // Opening Notification Center reveals many old notifications at once; never peek those.
        guard !fresh.isEmpty, fresh.count <= 3 else { return }

        stateLock.lock()
        let handler = _handler
        stateLock.unlock()
        guard let handler else { return }

        for banner in fresh {
            let notification = IslandNotification(
                bundleIdentifier: banner.bundleIdentifier,
                appName: banner.appName ?? "Notification",
                title: banner.title,
                subtitle: banner.subtitle,
                body: banner.body,
                source: "ax"
            )
            log.notice("Banner from \(notification.appName, privacy: .public)")
            DispatchQueue.main.async { handler(notification) }
            if closesSystemBanners {
                closeSystemBanner(banner)
            }
        }
    }

    /// Closes the macOS banner shortly after Isle shows its own peek.
    private func closeSystemBanner(_ banner: ParsedBanner) {
        guard let element = banner.element, let action = banner.closeAction else {
            FileLog.write("ax: banner has no close action")
            return
        }
        worker.perform(after: 0.4) {
            let result = AXUIElementPerformAction(element, action as CFString)
            if result != .success {
                FileLog.write("ax: closing banner failed (\(result.rawValue))")
            }
        }
    }
}

/// A thread that runs its own run loop so AX observers and timers can live off the main thread.
final class RunLoopThread {
    private var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)
    private let thread: Thread

    init(name: String) {
        var capturedLoop: CFRunLoop?
        let semaphore = ready
        thread = Thread {
            capturedLoop = CFRunLoopGetCurrent()
            // A port keeps the run loop alive even with no other sources.
            RunLoop.current.add(NSMachPort(), forMode: .default)
            semaphore.signal()
            while !Thread.current.isCancelled {
                RunLoop.current.run(mode: .default, before: .distantFuture)
            }
        }
        thread.name = name
        thread.qualityOfService = .userInitiated
        thread.start()
        ready.wait()
        runLoop = capturedLoop
    }

    func perform(_ block: @escaping () -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    func perform(after delay: TimeInterval, _ block: @escaping () -> Void) {
        perform {
            let timer = Timer(timeInterval: delay, repeats: false) { _ in block() }
            RunLoop.current.add(timer, forMode: .default)
        }
    }
}
