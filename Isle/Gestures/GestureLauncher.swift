import AppKit
import Combine

/// Hold left ⌥ → camera on and the island shows what it sees; a steady hand sign opens
/// its app. Releasing ⌥ (or pressing any other key / clicking) turns the camera off.
///
/// Only a `flagsChanged` monitor is installed permanently (it fires on modifier changes,
/// not on typing). Key and click monitors exist only while ⌥ is held.
@MainActor
final class GestureLauncher {
    /// Device-dependent flag for the left Option key (NX_DEVICELALTKEYMASK).
    private static let leftOptionMask: UInt = 0x20
    private static let otherModifiers: NSEvent.ModifierFlags = [.command, .control, .shift]

    private let store: IslandStateStore
    private let settings: AppSettings
    private let camera = HandGestureCamera()
    private var flagMonitors: [Any] = []
    private var holdMonitors: [Any] = []
    private var isHolding = false
    private var clearTask: DispatchWorkItem?
    /// "Opening VS Code" / error feedback stays at least until then.
    private var feedbackUntil = Date.distantPast
    private var cancellables = Set<AnyCancellable>()

    init(store: IslandStateStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        camera.onCandidate = { [weak self] gesture in
            guard let self, self.isHolding else { return }
            self.store.setGestureStatus(.listening(gesture))
        }
        camera.onConfirmed = { [weak self] gesture in self?.open(gesture) }
        camera.onFailure = { [weak self] failure in self?.handle(failure) }

        settings.$gesturesEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                if enabled { self?.start() } else { self?.stop() }
            }
            .store(in: &cancellables)
    }

    private func start() {
        guard flagMonitors.isEmpty else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.flagsChanged(event) }
        }) {
            flagMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.flagsChanged(event)
            return event
        }) {
            flagMonitors.append(local)
        }
        FileLog.write("gestures: listening for left Option")
    }

    func stop() {
        endHold()
        flagMonitors.forEach(NSEvent.removeMonitor)
        flagMonitors.removeAll()
    }

    // MARK: Keys

    private func flagsChanged(_ event: NSEvent) {
        let leftOption = event.modifierFlags.rawValue & Self.leftOptionMask != 0
        let others = !event.modifierFlags.intersection(Self.otherModifiers).isEmpty
        if leftOption, !others, !isHolding {
            beginHold()
        } else if isHolding, !leftOption || others {
            endHold()
        }
    }

    private func beginHold() {
        isHolding = true
        clearTask?.cancel()
        store.setGestureStatus(.listening(nil))
        camera.start()
        // Typing (⌥E → é), clicking (⌥-click) or scrolling with ⌥ held means it isn't a gesture.
        let cancelMask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: cancelMask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.endHold() }
        }) {
            holdMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: cancelMask, handler: { [weak self] event in
            self?.endHold()
            return event
        }) {
            holdMonitors.append(local)
        }
    }

    private func endHold() {
        guard isHolding else { return }
        isHolding = false
        camera.stop()
        holdMonitors.forEach(NSEvent.removeMonitor)
        holdMonitors.removeAll()
        let remaining = feedbackUntil.timeIntervalSinceNow
        if remaining > 0 {
            scheduleClear(after: remaining)
        } else {
            clearTask?.cancel()
            store.setGestureStatus(nil)
        }
    }

    // MARK: Results

    private func open(_ gesture: HandGesture) {
        guard isHolding else { return }
        let target = gesture.target
        // Done: camera off right away, even if ⌥ is still held.
        camera.stop()
        guard let url = target.applicationURL else {
            FileLog.write("gestures: \(gesture.rawValue) → \(target.name) not installed")
            showBriefly(.unavailable("\(target.name) not found"))
            return
        }
        FileLog.write("gestures: \(gesture.rawValue) → opening \(target.name)")
        showBriefly(.opening(gesture))
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                FileLog.write("gestures: opening \(target.name) failed: \(error.localizedDescription)")
            }
        }
    }

    private func handle(_ failure: HandGestureCamera.Failure) {
        let message: String
        switch failure {
        case .denied: message = "Camera access is off"
        case .noCamera: message = "No camera found"
        case .configuration(let detail): message = "Camera error"
            FileLog.write("gestures: camera configuration failed: \(detail)")
        }
        FileLog.write("gestures: \(message)")
        guard isHolding else { return }
        showBriefly(.unavailable(message))
    }

    private func showBriefly(_ status: IslandStateStore.GestureStatus) {
        store.setGestureStatus(status)
        feedbackUntil = Date().addingTimeInterval(1.2)
        scheduleClear(after: 1.2)
    }

    /// Clears the feedback later, unless ⌥ is held again by then (a new attempt owns the island).
    private func scheduleClear(after delay: TimeInterval) {
        clearTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self, !self.isHolding else { return }
            self.store.setGestureStatus(nil)
        }
        clearTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }
}
