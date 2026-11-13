import AppKit
import SwiftUI
import Combine

/// Hosting view that accepts the first click even though the panel never becomes key.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the notch panel: positions it on the right screen, keeps it there when
/// displays change, and routes pointer hover/clicks to the state store.
///
/// The panel is a fixed-size transparent window. It ignores mouse events
/// except while the pointer is over the island's current shape, so the menu
/// bar underneath stays clickable.
@MainActor
final class NotchWindowController {
    private let store: IslandStateStore
    private let settings: AppSettings
    private let panel: NotchPanel
    /// A full-screen app (window covering the whole notch screen) is frontmost.
    private var isFullScreenAppActive = false
    private var screen: NSScreen?
    private var cancellables = Set<AnyCancellable>()
    private var monitors: [Any] = []

    init(store: IslandStateStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        panel = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 260))

        let hosting = FirstMouseHostingView(rootView: IslandRootView(store: store))
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = panel.contentLayoutRect
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hosting

        observeScreens()
        observePointer()

        store.$state
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateMouseHandling(at: NSEvent.mouseLocation)
                self?.updateVisibility()
            }
            .store(in: &cancellables)

        settings.$hideInFullScreen
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateVisibility() }
            }
            .store(in: &cancellables)
    }

    func show() {
        reposition()
        panel.orderFrontRegardless()
    }

    func tearDown() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors.removeAll()
        panel.orderOut(nil)
    }

    /// Re-reads notch geometry and moves the panel. Called on launch and on every screen change.
    func reposition() {
        guard let screen = NotchGeometry.preferredScreen() else {
            panel.orderOut(nil)
            return
        }
        self.screen = screen
        let metrics = NotchGeometry.metrics(for: screen)
        store.updateMetrics(metrics)
        panel.setFrame(NotchGeometry.panelFrame(for: screen, metrics: metrics), display: true)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        updateMouseHandling(at: NSEvent.mouseLocation)
    }

    // MARK: Observation

    private func observeScreens() {
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .merge(with: NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification))
            .merge(with: NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification))
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reposition() }
            .store(in: &cancellables)

        // Full-screen detection: app switches and Space changes (entering full screen
        // moves the app to its own Space). Re-check after the transition animation.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .merge(with: NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification))
            .sink { [weak self] _ in
                self?.checkFullScreen()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self?.checkFullScreen() }
            }
            .store(in: &cancellables)
    }

    private func checkFullScreen() {
        guard let screen else { return }
        let active = Self.frontmostAppIsFullScreen(on: screen)
        guard active != isFullScreenAppActive else { return }
        isFullScreenAppActive = active
        FileLog.write("window: full-screen app \(active ? "active" : "inactive")")
        updateVisibility()
    }

    /// Hides the island over full-screen apps (setting), but always lets peeks through.
    private func updateVisibility() {
        let hide = settings.hideInFullScreen && isFullScreenAppActive && !store.state.isPeek
        let target: CGFloat = hide ? 0 : 1
        guard panel.alphaValue != target else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = target
        }
        if hide {
            panel.ignoresMouseEvents = true
        }
    }

    /// True when the frontmost app has a normal-layer window exactly covering `screen`.
    /// Window bounds and owners are readable without Screen Recording permission.
    private static func frontmostAppIsFullScreen(on screen: NSScreen) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier != Bundle.main.bundleIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        // CoreGraphics uses a top-left origin relative to the primary display.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let target = CGRect(
            x: screen.frame.minX,
            y: primaryHeight - screen.frame.maxY,
            width: screen.frame.width,
            height: screen.frame.height
        )
        for info in windows {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == front.processIdentifier,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else { continue }
            if abs(bounds.minX - target.minX) < 2, abs(bounds.minY - target.minY) < 2,
               abs(bounds.width - target.width) < 2, abs(bounds.height - target.height) < 2 {
                return true
            }
        }
        return false
    }

    private func observePointer() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            let location = NSEvent.mouseLocation
            Task { @MainActor in self?.updateMouseHandling(at: location) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.updateMouseHandling(at: NSEvent.mouseLocation)
            return event
        }) {
            monitors.append(local)
        }
    }

    private func updateMouseHandling(at location: NSPoint) {
        guard let screen else { return }
        let state = store.state
        let rect = NotchGeometry.islandRect(for: state, screen: screen, metrics: store.metrics, battery: store.showsBatteryWing)
        // Small tolerance so the top edge (y == screen max) counts as inside.
        let inside = rect.insetBy(dx: -2, dy: -2).contains(location)
        let hidden = panel.alphaValue < 0.5
        // The battery wing is display-only: clicks pass through to the menu bar.
        let interactive = inside && state != .idle && state != .battery && !hidden
        if panel.ignoresMouseEvents == interactive {
            panel.ignoresMouseEvents = !interactive
        }
        store.setHovering(inside)
    }
}
